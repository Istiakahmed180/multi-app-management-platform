import 'dart:convert';

import '../../core/models/models.dart';

final hexColorPattern = RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$');
final semverPattern = RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$');
final configKeyPattern = RegExp(r'^[a-z][a-z0-9_.-]{0,63}$');

String? validateHex(String? v) => (v != null && hexColorPattern.hasMatch(v)) ? null : 'Use #RRGGBB';
String? validateOptionalSemver(String? v) => (v == null || v.isEmpty || semverPattern.hasMatch(v)) ? null : 'Use x.y.z';
String? validateOptionalHttps(String? v) => (v == null || v.isEmpty || v.startsWith('https://')) ? null : 'Must start with https://';

/// Parses `#RRGGBB` / `#RRGGBBAA` into an ARGB int, or null when invalid.
int? parseHexColor(String? hex) {
  if (hex == null || !hexColorPattern.hasMatch(hex)) return null;
  final rgb = int.parse(hex.substring(1, 7), radix: 16);
  final alpha = hex.length == 9 ? int.parse(hex.substring(7, 9), radix: 16) : 0xFF;
  return (alpha << 24) | rgb;
}

Object? getPath(Json root, String path) {
  Object? cur = root;
  for (final part in path.split('.')) {
    if (cur is Map) {
      cur = cur[part];
    } else if (cur is List) {
      final i = int.tryParse(part);
      if (i == null || i < 0 || i >= cur.length) return null;
      cur = cur[i];
    } else {
      return null;
    }
  }
  return cur;
}

void setPath(Json root, String path, Object? value) {
  final parts = path.split('.');
  Object? cur = root;
  for (var i = 0; i < parts.length - 1; i++) {
    final p = parts[i];
    cur = cur is Map ? cur[p] : (cur is List ? cur[int.parse(p)] : null);
  }
  final last = parts.last;
  if (cur is Map) {
    cur[last] = value;
  } else if (cur is List) {
    cur[int.parse(last)] = value;
  }
}

Json deepCopy(Json source) => asJson(jsonDecode(jsonEncode(source)));

/// Flattens nested JSON into `path -> value` for diffing versions.
Map<String, Object?> flatten(Object? value, [String prefix = '']) {
  final out = <String, Object?>{};
  if (value is Map) {
    if (value.isEmpty && prefix.isNotEmpty) out[prefix] = '{}';
    value.forEach((k, v) => out.addAll(flatten(v, prefix.isEmpty ? '$k' : '$prefix.$k')));
  } else if (value is List) {
    if (value.isEmpty && prefix.isNotEmpty) out[prefix] = '[]';
    for (var i = 0; i < value.length; i++) {
      out.addAll(flatten(value[i], '$prefix.$i'));
    }
  } else {
    out[prefix] = value;
  }
  return out;
}

class ConfigChange {
  const ConfigChange(this.path, this.before, this.after);
  final String path;
  final Object? before;
  final Object? after;
}

List<ConfigChange> diffConfigs(Json before, Json after) {
  final a = flatten(before);
  final b = flatten(after);
  final keys = {...a.keys, ...b.keys}.toList()..sort();
  return [
    for (final k in keys)
      if (a[k] != b[k]) ConfigChange(k, a[k], b[k]),
  ];
}
