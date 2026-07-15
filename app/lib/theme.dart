import 'package:flutter/material.dart';

// Note colors live in SettingsStore (user-customizable palette); this file
// only builds the app-wide themes.

/// The app's default accent — Keep's amber. Users can override it in Settings;
/// [SettingsStore] stores the choice and feeds it back in as [buildTheme]'s
/// seed, so one color reseeds the whole Material scheme for both brightnesses.
const Color kDefaultAccent = Color(0xFFFBBC04);

ThemeData buildTheme(Brightness brightness, {Color seed = kDefaultAccent}) {
  final light = brightness == Brightness.light;
  // Neutralize the seed's cast on surfaces — Keep pairs a colored accent with
  // plain gray/white neutrals, so we keep the surfaces neutral whatever the
  // accent is and let the seed drive only `primary` and its companions.
  final scheme =
      ColorScheme.fromSeed(
        seedColor: seed,
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
  // A whisper-grey canvas so white note cards lift off the background. In dark
  // mode the canvas sits a hair *above* the surface, so plain (surface-filled)
  // cards read as distinct instead of blending into the background.
  final canvas = light ? const Color(0xFFF8F9FA) : const Color(0xFF26272A);
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
