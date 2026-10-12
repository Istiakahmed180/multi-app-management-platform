import 'dart:convert';

import 'json.dart';

/// A persisted response: the raw JSON body as received, its ETag and when it
/// was fetched.
final class StoredConfig {
  const StoredConfig({
    required this.rawJson,
    required this.fetchedAt,
    this.etag,
  });

  /// Throws [FormatException] if [json] is not a valid envelope.
  factory StoredConfig.fromJson(Object? json) {
    final object = JsonObject.from(json);
    return StoredConfig(
      rawJson: object.requireString('rawJson'),
      etag: object.optString('etag'),
      fetchedAt: object.requireDateTime('fetchedAt'),
    );
  }

  final String rawJson;
  final String? etag;
  final DateTime fetchedAt;

  Map<String, Object?> toJson() => {
    'rawJson': rawJson,
    'etag': etag,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
  };

  /// Serializes to a single string, convenient for key-value stores.
  String encode() => jsonEncode(toJson());

  /// The inverse of [encode]. Returns `null` for `null` or corrupt input.
  static StoredConfig? tryDecode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      return StoredConfig.fromJson(jsonDecode(source));
    } on FormatException {
      return null;
    }
  }
}

/// Persistence for the last-known-good configuration.
///
/// Implementations should return `null` from [read] rather than throw when
/// the data is missing or unreadable; the client also tolerates exceptions
/// and corrupt payloads, treating them as an empty store.
abstract class ConfigStore {
  Future<StoredConfig?> read();

  Future<void> write(StoredConfig config);

  Future<void> clear();
}

/// A [ConfigStore] that keeps data in memory only; nothing survives a restart.
final class InMemoryConfigStore implements ConfigStore {
  InMemoryConfigStore([this._value]);

  StoredConfig? _value;

  @override
  Future<StoredConfig?> read() async => _value;

  @override
  Future<void> write(StoredConfig config) async => _value = config;

  @override
  Future<void> clear() async => _value = null;
}
