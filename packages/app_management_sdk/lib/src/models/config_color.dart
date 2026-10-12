/// A color from the remote config, stored as a 32-bit ARGB integer.
///
/// In Flutter use `Color(configColor.colorValue)`.
final class ConfigColor {
  /// Creates a color from a 32-bit ARGB value, e.g. `0xFF2563EB`.
  const ConfigColor(this.colorValue);

  static final RegExp _hex = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

  /// Parses `#RRGGBB` or `#RRGGBBAA`; throws [FormatException] otherwise.
  factory ConfigColor.parse(String input) {
    final match = _hex.firstMatch(input.trim());
    if (match == null) {
      throw FormatException(
        'Invalid color, expected #RRGGBB or #RRGGBBAA',
        input,
      );
    }
    final digits = match[1]!;
    final rgb = int.parse(digits.substring(0, 6), radix: 16);
    final alpha = digits.length == 8
        ? int.parse(digits.substring(6, 8), radix: 16)
        : 0xFF;
    return ConfigColor((alpha << 24) | rgb);
  }

  final int colorValue;

  int get alpha => (colorValue >>> 24) & 0xFF;
  int get red => (colorValue >>> 16) & 0xFF;
  int get green => (colorValue >>> 8) & 0xFF;
  int get blue => colorValue & 0xFF;

  /// `#RRGGBB` for opaque colors, `#RRGGBBAA` otherwise.
  String toHex() {
    String hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    final rgb = '#${hex(red)}${hex(green)}${hex(blue)}';
    return alpha == 0xFF ? rgb : '$rgb${hex(alpha)}';
  }

  @override
  bool operator ==(Object other) =>
      other is ConfigColor && other.colorValue == colorValue;

  @override
  int get hashCode => colorValue.hashCode;

  @override
  String toString() => 'ConfigColor(${toHex()})';
}
