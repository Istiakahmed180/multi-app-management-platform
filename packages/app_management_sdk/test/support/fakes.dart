import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:dio/dio.dart';

const testAppKey = 'app_test123';
const testBaseUrl = 'https://config.example.com';

typedef FakeHandler =
    FutureOr<ResponseBody> Function(
      RequestOptions options,
      Future<void>? cancelFuture,
    );

/// An [HttpClientAdapter] that records requests and answers from a queue of
/// handlers (the last one repeats once the queue is drained).
final class FakeAdapter implements HttpClientAdapter {
  FakeAdapter([List<FakeHandler>? handlers]) : _handlers = [...?handlers];

  final List<FakeHandler> _handlers;
  final List<RequestOptions> requests = [];

  void enqueue(FakeHandler handler) => _handlers.add(handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_handlers.isEmpty) throw StateError('No fake response queued');
    final handler = _handlers.length > 1 ? _handlers.removeAt(0) : _handlers[0];
    return handler(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

FakeHandler respond(
  int status, {
  Object? json,
  String? body,
  String? etag,
  Map<String, String> headers = const {},
}) {
  return (_, _) => ResponseBody.fromString(
    body ?? (json == null ? '' : jsonEncode(json)),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
      'etag': ?(etag == null ? null : [etag]),
      for (final MapEntry(:key, :value) in headers.entries) key: [value],
    },
  );
}

FakeHandler throwing(DioExceptionType type) =>
    (options, _) => throw DioException(requestOptions: options, type: type);

/// Never answers; completes only when the request is cancelled.
FakeHandler hanging() => (options, cancelFuture) async {
  await (cancelFuture ?? Completer<void>().future);
  throw DioException.requestCancelled(
    requestOptions: options,
    reason: 'cancelled',
  );
};

/// Waits for [gate] before answering with [inner].
FakeHandler gated(Future<void> gate, FakeHandler inner) =>
    (options, cancel) async {
      await gate;
      return inner(options, cancel);
    };

Map<String, Object?> fullPayload({
  int configVersion = 3,
  String appKey = testAppKey,
  int schemaVersion = 1,
  Map<String, Object?>? features,
  List<Map<String, Object?>>? banners,
  Map<String, Object?>? updatePolicy,
  bool maintenance = false,
}) => {
  'schemaVersion': schemaVersion,
  'appKey': appKey,
  'configVersion': configVersion,
  'publishedAt': '2026-10-12T10:00:00.000Z',
  'config': {
    'branding': {
      'appTitle': 'Shop',
      'logoUrl': 'https://cdn.example.com/l.png',
    },
    'theme': {
      'defaultMode': 'dark',
      'darkModeEnabled': true,
      'light': {
        'primary': '#2563EB',
        'secondary': '#7C3AED',
        'background': '#FFFFFF',
        'surface': '#F8FAFC',
        'error': '#DC2626',
      },
      'dark': {
        'primary': '#60A5FA80',
        'secondary': '#A78BFA',
        'background': '#0B1120',
        'surface': '#111827',
        'error': '#F87171',
      },
    },
    'maintenance': {
      'enabled': maintenance,
      'title': 'Down',
      'message': 'Back soon',
      'estimatedEndAt': '2026-10-12T12:00:00.000Z',
    },
    'updatePolicy':
        updatePolicy ??
        {
          'android': {
            'minimumVersion': '1.2.0',
            'latestVersion': '1.4.0',
            'updateUrl': 'https://play.google.com/store/apps/details?id=x',
          },
          'ios': {
            'minimumVersion': null,
            'latestVersion': null,
            'updateUrl': null,
          },
          'message': 'Please update',
        },
    'banners':
        banners ??
        [
          {
            'id': 'sale',
            'title': 'Sale',
            'subtitle': null,
            'imageUrl': null,
            'actionUrl': null,
            'priority': 1,
            'startsAt': null,
            'endsAt': null,
          },
        ],
    'onboarding': {
      'enabled': true,
      'pages': [
        {'title': 'Welcome', 'body': 'Hello', 'imageUrl': null},
      ],
    },
    'strings': {'home.welcome': 'Hi'},
  },
  'features':
      features ??
      {
        'new_checkout': {
          'enabled': true,
          'rolloutPercentage': 100,
          'platforms': ['android'],
          'minAppVersion': '2.1.0',
        },
      },
};

Map<String, Object?> minimalPayload({int configVersion = 1}) => {
  'schemaVersion': 1,
  'appKey': testAppKey,
  'configVersion': configVersion,
  'publishedAt': '2026-10-12T10:00:00.000Z',
  'config': <String, Object?>{},
};

/// A client wired to [adapter] with a fixed clock.
AppManagementClient buildClient(
  FakeAdapter adapter, {
  ConfigStore? store,
  AppPlatform platform = AppPlatform.android,
  String appVersion = '2.1.0',
  String installationId = 'install-1',
  Duration timeout = const Duration(seconds: 8),
  DateTime Function()? now,
  bool rejectOlderConfigVersions = false,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return AppManagementClient(
    baseUrl: testBaseUrl,
    appKey: testAppKey,
    platform: platform,
    appVersion: appVersion,
    installationId: installationId,
    store: store,
    timeout: timeout,
    dio: dio,
    now: now ?? () => DateTime.utc(2026, 10, 12, 11),
    rejectOlderConfigVersions: rejectOlderConfigVersions,
  );
}

/// A store whose operations always fail.
final class ThrowingStore implements ConfigStore {
  @override
  Future<StoredConfig?> read() async => throw StateError('read failed');

  @override
  Future<void> write(StoredConfig config) async =>
      throw StateError('write failed');

  @override
  Future<void> clear() async {}
}
