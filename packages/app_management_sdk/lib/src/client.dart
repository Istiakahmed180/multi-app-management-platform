import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'config_error.dart';
import 'config_store.dart';
import 'fnv1a.dart' as fnv;
import 'json.dart';
import 'models/app_config.dart';
import 'models/remote_config_snapshot.dart';
import 'platform.dart';
import 'refresh_result.dart';
import 'semver.dart';
import 'update_status.dart';

/// Fetches, caches and evaluates the published configuration for one app.
///
/// Typical lifecycle: construct once at startup, call [initialize], listen to
/// [changes], call [refresh] when the app resumes, and [dispose] on shutdown.
class AppManagementClient {
  /// Creates a client.
  ///
  /// [appKey] is a public identifier, not a credential. [installationId] is a
  /// stable random id persisted by the host app; it is only used for
  /// percentage rollout bucketing and is never sent to the server.
  ///
  /// When [rejectOlderConfigVersions] is `true`, a payload whose
  /// `configVersion` is lower than the cached one is rejected as
  /// [ConfigErrorKind.staleVersion]. It defaults to `false` so the server
  /// stays authoritative, e.g. after a backend restore.
  ///
  /// Throws [ArgumentError] for an invalid [baseUrl], [appVersion], empty
  /// [appKey]/[installationId] or non-positive [timeout].
  AppManagementClient({
    required String baseUrl,
    required this.appKey,
    required this.platform,
    required String appVersion,
    required this.installationId,
    ConfigStore? store,
    Duration timeout = const Duration(seconds: 8),
    Dio? dio,
    DateTime Function()? now,
    this.rejectOlderConfigVersions = false,
  }) : appVersion = _parseAppVersion(appVersion),
       _endpoint = _buildEndpoint(baseUrl, appKey, platform),
       _store = store ?? InMemoryConfigStore(),
       _timeout = timeout,
       _ownsDio = dio == null,
       _dio =
           dio ??
           Dio(BaseOptions(connectTimeout: timeout, receiveTimeout: timeout)),
       _now = now ?? DateTime.now {
    if (appKey.trim().isEmpty) {
      throw ArgumentError.value(appKey, 'appKey', 'must not be empty');
    }
    if (installationId.trim().isEmpty) {
      throw ArgumentError.value(
        installationId,
        'installationId',
        'must not be empty',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  final String appKey;
  final AppPlatform platform;
  final SemanticVersion appVersion;
  final String installationId;
  final bool rejectOlderConfigVersions;

  final Uri _endpoint;
  final ConfigStore _store;
  final Duration _timeout;
  final bool _ownsDio;
  final Dio _dio;
  final DateTime Function() _now;
  final StreamController<RemoteConfigSnapshot> _changes =
      StreamController<RemoteConfigSnapshot>.broadcast();

  RemoteConfigSnapshot? _current;
  String? _etag;
  DateTime? _lastFetchedAt;
  Future<RemoteConfigSnapshot?>? _initializing;
  Future<RefreshResult>? _inFlight;
  CancelToken? _cancelToken;
  bool _disposed = false;

  /// The request URL, e.g. `https://host/api/v1/public/apps/app_x/config?platform=ios`.
  Uri get endpoint => _endpoint;

  /// The last-known-good snapshot, or `null` before anything was loaded.
  RemoteConfigSnapshot? get current => _current;

  /// When [current] was last fetched or confirmed by the server.
  DateTime? get lastFetchedAt => _lastFetchedAt;

  /// Emits each newly applied snapshot: the cached one restored by
  /// [initialize] and every [RefreshUpdated]. Not emitted for 304s or failures.
  Stream<RemoteConfigSnapshot> get changes => _changes.stream;

  /// Restores the cached snapshot (emitting it), then refreshes from the
  /// network. Never throws on network or storage failure. Repeated calls
  /// return the same future.
  ///
  /// Returns [current] after the refresh attempt, which may still be the
  /// cached snapshot or `null` if offline with an empty cache.
  Future<RemoteConfigSnapshot?> initialize() {
    _ensureNotDisposed();
    return _initializing ??= () async {
      await _restoreFromStore();
      if (!_disposed) await refresh();
      return _current;
    }();
  }

  /// Fetches the latest config, using `If-None-Match` when a snapshot is
  /// cached. Concurrent calls share one request. Never throws; failures are
  /// returned as [RefreshFailed] and [current] is left untouched.
  Future<RefreshResult> refresh() {
    _ensureNotDisposed();
    return _inFlight ??= _performRefresh().whenComplete(() => _inFlight = null);
  }

  /// Cancels any in-flight request and closes [changes]. The injected [Dio],
  /// if any, is left open for its owner.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelToken?.cancel('disposed');
    if (_ownsDio) _dio.close(force: true);
    await _changes.close();
  }

  /// Whether the flag [key] is on for this installation: present and enabled,
  /// targeted at this platform, `appVersion >= minAppVersion`, and inside the
  /// rollout percentage. Unparseable `minAppVersion` values fail closed.
  bool isFeatureEnabled(String key) {
    final flag = _current?.features[key];
    if (flag == null || !flag.enabled) return false;
    if (flag.platforms.isNotEmpty &&
        !flag.platforms.contains(platform.wireName)) {
      return false;
    }
    final minVersion = flag.minAppVersion;
    if (minVersion != null) {
      final required = SemanticVersion.tryParse(minVersion);
      if (required == null || appVersion < required) return false;
    }
    return rolloutBucket(key) < flag.rolloutPercentage;
  }

  /// This installation's bucket in `[0, 100)` for [flagKey]:
  /// `FNV-1a32("$flagKey:$installationId") % 100`.
  int rolloutBucket(String flagKey) =>
      fnv.rolloutBucket(flagKey, installationId);

  /// Compares [appVersion] with the current platform's update policy.
  ///
  /// The SDK only reports; enforcing [UpdateLevel.required] (e.g. a blocking
  /// screen linking to [UpdateStatus.updateUrl]) is the host app's job.
  /// Unparseable policy versions are ignored.
  UpdateStatus updateStatus() {
    final updatePolicy = _current?.config.updatePolicy ?? const UpdatePolicy();
    final policy = updatePolicy.forPlatform(platform);
    final minimum = SemanticVersion.tryParse(policy.minimumVersion);
    final latest = SemanticVersion.tryParse(policy.latestVersion);
    final level = switch (appVersion) {
      final v when minimum != null && v < minimum => UpdateLevel.required,
      final v when latest != null && v < latest => UpdateLevel.recommended,
      _ => UpdateLevel.upToDate,
    };
    return UpdateStatus(
      level: level,
      currentVersion: appVersion,
      minimumVersion: minimum,
      latestVersion: latest,
      updateUrl: policy.updateUrl,
      message: updatePolicy.message,
    );
  }

  bool get isInMaintenance => _current?.config.maintenance.enabled ?? false;

  /// Banners whose time window contains [at] (default: now), highest
  /// priority first; ties keep their published order.
  List<RemoteBanner> activeBanners({DateTime? at}) {
    final moment = (at ?? _now()).toUtc();
    final banners = _current?.config.banners ?? const <RemoteBanner>[];
    final indexed = [
      for (final (i, banner) in banners.indexed)
        if (banner.isActiveAt(moment)) (i, banner),
    ];
    indexed.sort((a, b) {
      final byPriority = b.$2.priority.compareTo(a.$2.priority);
      return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
    });
    return List.unmodifiable(indexed.map((e) => e.$2));
  }

  /// A remote string by key, or `null` if absent.
  String? string(String key) => _current?.config.strings[key];

  Future<void> _restoreFromStore() async {
    final StoredConfig? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      return;
    }
    if (stored == null || _current != null || _disposed) return;
    final (snapshot, error) = _parseSnapshot(stored.rawJson);
    if (snapshot == null || error != null) return;
    _apply(snapshot, stored.etag, stored.fetchedAt);
  }

  Future<RefreshResult> _performRefresh() async {
    final cached = _current;
    final etag = cached == null ? null : _etag;
    final cancelToken = _cancelToken = CancelToken();
    var timedOut = false;
    final deadline = Timer(_timeout, () {
      timedOut = true;
      cancelToken.cancel('timeout');
    });

    final Response<String> response;
    try {
      response = await _dio.getUri<String>(
        _endpoint,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: _timeout,
          validateStatus: (_) => true,
          headers: {'Accept': 'application/json', 'If-None-Match': ?etag},
        ),
      );
    } on DioException catch (e) {
      return _fail(_mapDioException(e, timedOut: timedOut));
    } catch (e) {
      return _fail(ConfigError(ConfigErrorKind.network, '$e', cause: e));
    } finally {
      deadline.cancel();
      _cancelToken = null;
    }

    return _handleResponse(response, cached);
  }

  Future<RefreshResult> _handleResponse(
    Response<String> response,
    RemoteConfigSnapshot? cached,
  ) async {
    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    switch (status) {
      case 200:
        return _accept(body, response.headers.value('etag'), cached);
      case 304:
        if (cached == null || !identical(cached, _current)) {
          return _fail(
            ConfigError(
              ConfigErrorKind.invalidPayload,
              'Received 304 without a matching cached configuration',
              statusCode: status,
            ),
          );
        }
        _lastFetchedAt = _now();
        return RefreshNotModified(cached);
      case 404:
        return _fail(
          ConfigError(
            ConfigErrorKind.notFound,
            _errorMessage(body) ?? 'App not found or nothing published',
            statusCode: status,
          ),
        );
      case 429:
        return _fail(
          ConfigError(
            ConfigErrorKind.rateLimited,
            _errorMessage(body) ?? 'Rate limited',
            statusCode: status,
            retryAfter: _parseRetryAfter(response.headers.value('retry-after')),
          ),
        );
      default:
        return _fail(
          ConfigError(
            ConfigErrorKind.server,
            _errorMessage(body) ?? 'Unexpected HTTP status $status',
            statusCode: status,
          ),
        );
    }
  }

  Future<RefreshResult> _accept(
    String body,
    String? etag,
    RemoteConfigSnapshot? cached,
  ) async {
    final (snapshot, error) = _parseSnapshot(body);
    if (error != null) return _fail(error);
    if (snapshot == null) {
      return _fail(
        const ConfigError(ConfigErrorKind.invalidPayload, 'Empty payload'),
      );
    }
    if (rejectOlderConfigVersions &&
        cached != null &&
        snapshot.configVersion < cached.configVersion) {
      return _fail(
        ConfigError(
          ConfigErrorKind.staleVersion,
          'configVersion ${snapshot.configVersion} is older than cached '
          '${cached.configVersion}',
        ),
      );
    }

    final fetchedAt = _now();
    try {
      await _store.write(
        StoredConfig(rawJson: body, etag: etag, fetchedAt: fetchedAt),
      );
    } catch (_) {
      // Persistence is best-effort; the fresh snapshot is still applied.
    }
    _apply(snapshot, etag, fetchedAt);
    return RefreshUpdated(snapshot);
  }

  /// Returns either a snapshot for this app or the reason it was rejected.
  (RemoteConfigSnapshot?, ConfigError?) _parseSnapshot(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final schemaVersion = JsonObject.from(
        decoded,
      ).requireInt('schemaVersion');
      if (schemaVersion > RemoteConfigSnapshot.supportedSchemaVersion) {
        return (
          null,
          ConfigError(
            ConfigErrorKind.unsupportedSchema,
            'schemaVersion $schemaVersion is newer than supported '
            '${RemoteConfigSnapshot.supportedSchemaVersion}',
          ),
        );
      }
      if (schemaVersion < 1) {
        throw FormatException('Invalid schemaVersion $schemaVersion');
      }
      final snapshot = RemoteConfigSnapshot.fromJson(decoded);
      if (snapshot.appKey != appKey) {
        return (
          null,
          ConfigError(
            ConfigErrorKind.invalidPayload,
            'Payload is for app "${snapshot.appKey}", expected "$appKey"',
          ),
        );
      }
      return (snapshot, null);
    } catch (e) {
      final message = e is FormatException ? e.message : '$e';
      return (
        null,
        ConfigError(ConfigErrorKind.invalidPayload, message, cause: e),
      );
    }
  }

  void _apply(RemoteConfigSnapshot snapshot, String? etag, DateTime fetchedAt) {
    if (_disposed) return;
    _current = snapshot;
    _etag = etag;
    _lastFetchedAt = fetchedAt;
    _changes.add(snapshot);
  }

  RefreshFailed _fail(ConfigError error) =>
      RefreshFailed(error, lastKnownGood: _current);

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('AppManagementClient was disposed');
  }

  static ConfigError _mapDioException(
    DioException e, {
    required bool timedOut,
  }) {
    final kind = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => ConfigErrorKind.timeout,
      DioExceptionType.cancel when timedOut => ConfigErrorKind.timeout,
      _ => ConfigErrorKind.network,
    };
    final message = kind == ConfigErrorKind.timeout
        ? 'Request timed out'
        : (e.message ?? e.error?.toString() ?? 'Network error');
    return ConfigError(kind, message, cause: e);
  }

  static String? _errorMessage(String body) {
    try {
      final error = JsonObject.from(jsonDecode(body)).optObject('error');
      return error?.optString('message');
    } catch (_) {
      return null;
    }
  }

  static Duration? _parseRetryAfter(String? value) {
    final seconds = int.tryParse(value?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  static SemanticVersion _parseAppVersion(String value) {
    final version = SemanticVersion.tryParse(value);
    if (version == null) {
      throw ArgumentError.value(value, 'appVersion', 'is not a semver string');
    }
    return version;
  }

  static Uri _buildEndpoint(
    String baseUrl,
    String appKey,
    AppPlatform platform,
  ) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null ||
        !(base.isScheme('https') || base.isScheme('http')) ||
        base.host.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must be an http(s) URL');
    }
    final segments = [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'api',
      'v1',
      'public',
      'apps',
      appKey,
      'config',
    ];
    return base.replace(
      pathSegments: segments,
      queryParameters: {'platform': platform.wireName},
    );
  }
}
