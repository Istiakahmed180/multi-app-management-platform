import 'package:flutter/material.dart';

class AppTheme {
  static const _seed = Color(0xFF4F46E5);

  static ThemeData light() => _build(ColorScheme.fromSeed(seedColor: _seed));

  static ThemeData dark() => _build(ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark));

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, visualDensity: VisualDensity.standard);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.brightness == Brightness.light ? const Color(0xFFF6F7FB) : scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: base.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
        dataRowMinHeight: 48,
        dataRowMaxHeight: 64,
        dividerThickness: 0.6,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
      ),
    );
  }
}
