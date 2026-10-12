/// Typed, path-aware accessors over decoded JSON.
///
/// Missing or `null` values fall back to defaults where a default makes
/// sense; values that are present but of the wrong type throw a
/// [FormatException] naming the offending path.
final class JsonObject {
  JsonObject._(this._map, this.path);

  /// Wraps [value], or returns it unchanged if it already is a [JsonObject]
  /// so nested parsers keep the full path in error messages.
  factory JsonObject.from(Object? value, [String path = r'$']) {
    if (value is JsonObject) return value;
    if (value is! Map<Object?, Object?>) {
      throw FormatException('Expected a JSON object at $path');
    }
    final map = <String, Object?>{};
    for (final MapEntry(:key, :value) in value.entries) {
      if (key is! String) {
        throw FormatException('Expected string keys at $path');
      }
      map[key] = value;
    }
    return JsonObject._(map, path);
  }

  final Map<String, Object?> _map;
  final String path;

  Iterable<String> get keys => _map.keys;

  Object? operator [](String key) => _map[key];

  String pathOf(String key) => '$path.$key';

  String requireString(String key) {
    final value = _map[key];
    if (value is String) return value;
    throw FormatException('Expected a string at ${pathOf(key)}');
  }

  String string(String key, {String fallback = ''}) {
    final value = _map[key];
    if (value == null) return fallback;
    if (value is String) return value;
    throw FormatException('Expected a string at ${pathOf(key)}');
  }

  /// Returns `null` for missing, `null`, or blank strings.
  String? optString(String key) {
    final value = string(key);
    return value.trim().isEmpty ? null : value;
  }

  int requireInt(String key) {
    final value = _map[key];
    if (value == null) {
      throw FormatException('Missing required integer at ${pathOf(key)}');
    }
    return _toInt(value, key);
  }

  int integer(String key, {required int fallback}) {
    final value = _map[key];
    return value == null ? fallback : _toInt(value, key);
  }

  int _toInt(Object value, String key) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.truncate()) {
      return value.toInt();
    }
    throw FormatException('Expected an integer at ${pathOf(key)}');
  }

  bool boolean(String key, {required bool fallback}) {
    final value = _map[key];
    if (value == null) return fallback;
    if (value is bool) return value;
    throw FormatException('Expected a boolean at ${pathOf(key)}');
  }

  DateTime requireDateTime(String key) {
    final value = optDateTime(key);
    if (value == null) {
      throw FormatException('Missing required timestamp at ${pathOf(key)}');
    }
    return value;
  }

  DateTime? optDateTime(String key) {
    final raw = optString(key);
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw FormatException('Invalid ISO-8601 timestamp at ${pathOf(key)}');
    }
    return parsed.toUtc();
  }

  JsonObject requireObject(String key) =>
      JsonObject.from(_map[key], pathOf(key));

  JsonObject? optObject(String key) {
    final value = _map[key];
    return value == null ? null : JsonObject.from(value, pathOf(key));
  }

  List<Object?> list(String key) {
    final value = _map[key];
    if (value == null) return const [];
    if (value is List<Object?>) return value;
    throw FormatException('Expected an array at ${pathOf(key)}');
  }

  List<T> mapList<T>(String key, T Function(JsonObject item) parse) {
    final items = list(key);
    return List.unmodifiable([
      for (var i = 0; i < items.length; i++)
        parse(JsonObject.from(items[i], '${pathOf(key)}[$i]')),
    ]);
  }

  List<String> stringList(String key) {
    final items = list(key);
    return List.unmodifiable([
      for (var i = 0; i < items.length; i++)
        if (items[i] case final String s)
          s
        else
          throw FormatException('Expected a string at ${pathOf(key)}[$i]'),
    ]);
  }

  Map<String, String> stringMap(String key) {
    final object = optObject(key);
    if (object == null) return const {};
    return Map.unmodifiable({
      for (final k in object.keys) k: object.requireString(k),
    });
  }
}

String? isoOrNull(DateTime? value) => value?.toUtc().toIso8601String();
