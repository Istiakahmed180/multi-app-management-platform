import '../json.dart';

/// A feature flag as published by the server.
///
/// Use `AppManagementClient.isFeatureEnabled` rather than reading [enabled]
/// directly: it also applies platform, version and rollout targeting.
final class FeatureFlag {
  const FeatureFlag({
    required this.key,
    this.enabled = false,
    this.rolloutPercentage = 100,
    this.platforms = const [],
    this.minAppVersion,
  });

  /// A missing `enabled` is treated as `false` (fail closed); a missing
  /// `rolloutPercentage` as 100. Percentages are clamped to `[0, 100]`.
  factory FeatureFlag.fromJson(String key, Object? data) {
    final json = JsonObject.from(data);
    return FeatureFlag(
      key: key,
      enabled: json.boolean('enabled', fallback: false),
      rolloutPercentage: json
          .integer('rolloutPercentage', fallback: 100)
          .clamp(0, 100),
      platforms: json.stringList('platforms'),
      minAppVersion: json.optString('minAppVersion'),
    );
  }

  final String key;
  final bool enabled;
  final int rolloutPercentage;

  /// Platform wire names (`android`, `ios`). Empty means all platforms.
  final List<String> platforms;
  final String? minAppVersion;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'rolloutPercentage': rolloutPercentage,
    'platforms': platforms,
    'minAppVersion': minAppVersion,
  };
}
