import 'package:flutter/material.dart';

// Note colors live in SettingsStore (user-customizable palette); this file
// only builds the app-wide themes.

/// The app's default accent — amber. Users can override it in Settings;
/// [SettingsStore] stores the choice and feeds it back in as [buildTheme]'s
/// seed, so one color reseeds the whole Material scheme for both brightnesses.
const Color kDefaultAccent = Color(0xFFFBBC04);

/// App-wide corner radius. The design favors near-square corners rather than
/// the pill/circular shapes Material defaults to — every piece of chrome
/// (cards, inputs, buttons, menus, dialogs, chips) rounds to this so the look
/// stays consistent. Change it here to retune the whole app.
const double kRadius = 4;

/// Menus are given a touch more rounding than controls and cards, helping the
/// floating surface read separately from the near-square note layout.
const double kMenuRadius = 6;

/// [kRadius] as a [Radius]/[BorderRadius] for the many hand-rolled containers
/// that can't read a shape from the theme.
const Radius kRadiusCorner = Radius.circular(kRadius);
const BorderRadius kBorderRadius = BorderRadius.all(kRadiusCorner);

/// A [RoundedRectangleBorder] at [kRadius], for widgets whose `shape` we set.
const RoundedRectangleBorder kRoundedShape = RoundedRectangleBorder(
  borderRadius: kBorderRadius,
);

/// The quietest line in the app. Chrome seams — the top bar's underline, the
/// sidebar and drawer edges, the separators inside them — should read as a
/// change of surface rather than a drawn rule, and `outlineVariant` at full
/// strength is too present over spans this long.
Color hairlineColor(ColorScheme scheme) =>
    scheme.outlineVariant.withValues(alpha: 0.5);

ThemeData buildTheme(Brightness brightness, {Color seed = kDefaultAccent}) {
  final light = brightness == Brightness.light;
  // Neutralize the seed's cast on surfaces — the design pairs a colored accent with
  // plain gray/white neutrals, so we keep the surfaces neutral whatever the
  // accent is and let the seed drive only `primary` and its companions.
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
      .copyWith(
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
      // Material rounds the drawer's trailing edge to 16; that lone big curve
      // reads as a different app next to everything else here. The side gives
      // it the same seam the top bar draws — only the trailing edge is ever
      // on screen, the other three sit under the device bezel.
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.horizontal(right: kRadiusCorner),
        side: BorderSide(color: hairlineColor(scheme)),
      ),
      endShape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.horizontal(left: kRadiusCorner),
        side: BorderSide(color: hairlineColor(scheme)),
      ),
    ),
    // Every rule in the app, including the separators inside the drawer.
    dividerTheme: base.dividerTheme.copyWith(color: hairlineColor(scheme)),
    // The drawer's selection indicator defaults to a stadium (fully rounded)
    // pill. Square it off to match the sidebar rail's own selection fill,
    // which is hand-rolled at [kRadius] (see _RowHighlight in app_drawer.dart).
    navigationDrawerTheme: base.navigationDrawerTheme.copyWith(
      indicatorShape: kRoundedShape,
    ),
    // Near-square corners everywhere the theme reaches. Hand-rolled containers
    // in individual widgets use [kBorderRadius]/[kRoundedShape] to match.
    cardTheme: base.cardTheme.copyWith(shape: kRoundedShape),
    dialogTheme: base.dialogTheme.copyWith(shape: kRoundedShape),
    // Popup menus borrow the compact, outlined floating-surface treatment used
    // by the motion preview: enough separation from the canvas without a
    // heavy Material dialog feel.
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: scheme.surface,
      elevation: 6,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: 0.14),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kMenuRadius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(shape: WidgetStatePropertyAll(kRoundedShape)),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: kRadiusCorner),
      ),
    ),
    // NOTE: no inputDecorationTheme border override on purpose. Flutter's
    // OutlineInputBorder already defaults to a 4px radius, so the fields that
    // opt into an outline (login, chat, settings) are boxy by default. Forcing
    // per-state borders here would also override the many `InputBorder.none`
    // fields (editor title/body, search, quick-add) and draw boxes they never
    // wanted.
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(kRoundedShape)),
    ),
    elevatedButtonTheme: const ElevatedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(kRoundedShape)),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(kRoundedShape)),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(kRoundedShape)),
    ),
    chipTheme: base.chipTheme.copyWith(shape: kRoundedShape),
    // SegmentedButton defaults to a stadium (pill) shape — square it off.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          kRoundedShape.copyWith(side: BorderSide(color: scheme.outline)),
        ),
      ),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      shape: kRoundedShape,
    ),
    // Light "elevated toast" snackbars — a raised surface card, not the dark
    // inverse bar, so they read as native to the note cards. showAppSnack
    // (util/snack.dart) fills in a tinted leading icon chip.
    snackBarTheme: base.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 96, 16),
      width: null,
      elevation: 6,
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 13.5,
      ),
      actionTextColor: scheme.primary,
      closeIconColor: scheme.onSurfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      waitDuration: const Duration(milliseconds: 600),
    ),
  );
}
