import 'dart:convert';

import '../json.dart';
import 'app_config.dart';
import 'feature_flag.dart';

/// An immutable, fully parsed configuration as published for one app.
final class RemoteConfigSnapshot {
  const RemoteConfigSnapshot({
    required this.schemaVersion,
    required this.appKey,
    required this.configVersion,
    required this.publishedAt,
    this.config = const AppConfig(),
    this.features = const {},
  });

  /// The highest `schemaVersion` this SDK understands.
  static const int supportedSchemaVersion = 1;

  /// Parses a decoded payload. Unknown fields are ignored and optional ones
  /// get defaults; a malformed required structure throws [FormatException].
  ///
  /// This does not check [schemaVersion] against [supportedSchemaVersion];
  /// the client does that before parsing.
  factory RemoteConfigSnapshot.fromJson(Object? json) {
    final root = JsonObject.from(json);
    final appKey = root.requireString('appKey');
    if (appKey.isEmpty) {
      throw FormatException('Empty appKey at ${root.pathOf('appKey')}');
    }
    final features = root.optObject('features');
    return RemoteConfigSnapshot(
      schemaVersion: root.requireInt('schemaVersion'),
      appKey: appKey,
      configVersion: root.requireInt('configVersion'),
      publishedAt: root.requireDateTime('publishedAt'),
      config: AppConfig.fromJson(root.requireObject('config')),
      features: features == null
          ? const {}
          : Map.unmodifiable({
              for (final key in features.keys)
                key: FeatureFlag.fromJson(key, features.requireObject(key)),
            }),
    );
  }

  /// Decodes and parses a JSON string; throws [FormatException] on failure.
  factory RemoteConfigSnapshot.fromJsonString(String source) =>
      RemoteConfigSnapshot.fromJson(jsonDecode(source));

  final int schemaVersion;
  final String appKey;

  /// Monotonically increasing publish counter.
  final int configVersion;
  final DateTime publishedAt;
  final AppConfig config;

  /// Enabled flags only; a missing key means the feature is disabled.
  final Map<String, FeatureFlag> features;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'appKey': appKey,
    'configVersion': configVersion,
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'config': config.toJson(),
    'features': {
      for (final MapEntry(:key, :value) in features.entries)
        key: value.toJson(),
    },
  };
}
