import 'package:flutter/material.dart';

// Note colors live in SettingsStore (user-customizable palette); this file
// only builds the app-wide themes.

ThemeData buildTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  // Neutralize the seed's amber cast on surfaces — Keep pairs a yellow accent
  // with plain gray/white neutrals.
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFFBBC04),
        brightness: brightness,
      ).copyWith(
        surface: light ? Colors.white : const Color(0xFF202124),
        surfaceContainerLow: light
            ? const Color(0xFFF8F9FA)
            : const Color(0xFF28292C),
        surfaceContainer: light
            ? const Color(0xFFF1F3F4)
            : const Color(0xFF2D2E31),
        surfaceContainerHigh: light
            ? const Color(0xFFF1F3F4)
            : const Color(0xFF35363A),
        surfaceContainerHighest: light
            ? const Color(0xFFE9EBEE)
            : const Color(0xFF3C3D41),
      );
  // A very light grey canvas so white note cards lift off the background.
  // (Dark mode keeps its darker surface, where cards are already lighter.)
  final canvas = light ? const Color(0xFFF4F5F7) : scheme.surface;
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    drawerTheme: base.drawerTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 96, 16),
      width: null,
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      waitDuration: const Duration(milliseconds: 600),
    ),
  );
}
