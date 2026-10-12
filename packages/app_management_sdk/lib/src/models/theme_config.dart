import '../json.dart';
import 'config_color.dart';

/// The theme mode the app should start in.
///
/// Unknown values from newer servers fall back to [system].
enum ConfigThemeMode {
  system,
  light,
  dark;

  static ConfigThemeMode fromWire(String? value) => switch (value) {
    'light' => light,
    'dark' => dark,
    _ => system,
  };
}

/// A set of semantic colors for one brightness.
final class ColorPalette {
  const ColorPalette({
    required this.primary,
    required this.secondary,
    required this.background,
    required this.surface,
    required this.error,
  });

  static const ColorPalette defaultLight = ColorPalette(
    primary: ConfigColor(0xFF2563EB),
    secondary: ConfigColor(0xFF7C3AED),
    background: ConfigColor(0xFFFFFFFF),
    surface: ConfigColor(0xFFF8FAFC),
    error: ConfigColor(0xFFDC2626),
  );

  static const ColorPalette defaultDark = ColorPalette(
    primary: ConfigColor(0xFF60A5FA),
    secondary: ConfigColor(0xFFA78BFA),
    background: ConfigColor(0xFF0B1120),
    surface: ConfigColor(0xFF111827),
    error: ConfigColor(0xFFF87171),
  );

  /// Missing colors are taken from [fallback]; invalid ones throw.
  factory ColorPalette.fromJson(
    Object? data, {
    ColorPalette fallback = defaultLight,
  }) {
    final json = JsonObject.from(data);
    ConfigColor read(String key, ConfigColor defaultColor) {
      final raw = json.optString(key);
      if (raw == null) return defaultColor;
      try {
        return ConfigColor.parse(raw);
      } on FormatException {
        throw FormatException('Invalid color at ${json.pathOf(key)}', raw);
      }
    }

    return ColorPalette(
      primary: read('primary', fallback.primary),
      secondary: read('secondary', fallback.secondary),
      background: read('background', fallback.background),
      surface: read('surface', fallback.surface),
      error: read('error', fallback.error),
    );
  }

  final ConfigColor primary;
  final ConfigColor secondary;
  final ConfigColor background;
  final ConfigColor surface;
  final ConfigColor error;

  Map<String, Object?> toJson() => {
    'primary': primary.toHex(),
    'secondary': secondary.toHex(),
    'background': background.toHex(),
    'surface': surface.toHex(),
    'error': error.toHex(),
  };
}

final class ThemeConfig {
  const ThemeConfig({
    this.defaultMode = ConfigThemeMode.system,
    this.darkModeEnabled = true,
    this.light = ColorPalette.defaultLight,
    this.dark = ColorPalette.defaultDark,
  });

  factory ThemeConfig.fromJson(Object? data) {
    final json = JsonObject.from(data);
    final light = json.optObject('light');
    final dark = json.optObject('dark');
    return ThemeConfig(
      defaultMode: ConfigThemeMode.fromWire(json.optString('defaultMode')),
      darkModeEnabled: json.boolean('darkModeEnabled', fallback: true),
      light: light == null
          ? ColorPalette.defaultLight
          : ColorPalette.fromJson(light),
      dark: dark == null
          ? ColorPalette.defaultDark
          : ColorPalette.fromJson(dark, fallback: ColorPalette.defaultDark),
    );
  }

  final ConfigThemeMode defaultMode;

  /// When `false` the app should stay in light mode regardless of
  /// [defaultMode] or the system setting.
  final bool darkModeEnabled;
  final ColorPalette light;
  final ColorPalette dark;

  /// The mode to apply, taking [darkModeEnabled] into account.
  ConfigThemeMode get effectiveMode =>
      darkModeEnabled ? defaultMode : ConfigThemeMode.light;

  Map<String, Object?> toJson() => {
    'defaultMode': defaultMode.name,
    'darkModeEnabled': darkModeEnabled,
    'light': light.toJson(),
    'dark': dark.toJson(),
  };
}
