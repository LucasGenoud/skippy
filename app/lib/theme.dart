import 'dart:math' as math;

import 'package:flutter/material.dart';

// Note colors live in SettingsStore (user-customizable palette); this file
// only builds the app-wide themes.
//
// THE DEPTH MODEL. Three layers, and every surface in the app is one of them:
//
//   * the canvas ([ColorScheme.surfaceDim]) is the ground everything sits on —
//     the scaffold background, and nothing else;
//   * surfaces ([ColorScheme.surface]) rise off it: note cards, the top bar,
//     the sidebar, dialogs, menus and toasts;
//   * troughs ([boardColumnColor]) recess into it: board columns, the one
//     container that has to read as a region cards are dropped *into*.
//
// Both directions used to be a couple of RGB units wide, which is why the app
// read as one flat sheet: a white card on an F8F9FA canvas is a 1.04:1
// difference, invisible on anything but a good display. `test/theme_test.dart`
// pins the separation, along with the contrast rules below.

/// The app's default accent, amber. Users can override it in Settings;
/// [SettingsStore] stores the choice and feeds it back in as [buildTheme]'s
/// seed, so one color reseeds the whole Material scheme for both brightnesses.
const Color kDefaultAccent = Color(0xFFFBBC04);

/// App-wide corner radius. The design favors near-square corners rather than
/// the pill/circular shapes Material defaults to, every piece of chrome
/// (cards, inputs, buttons, menus, dialogs, chips) rounds to this so the look
/// stays consistent. Change it here to retune the whole app.
const double kRadius = 4;

/// Menus are given a touch more rounding than controls and cards, helping the
/// floating surface read separately from the near-square note layout.
const double kMenuRadius = 6;

/// Shared layout rhythm for the compact controls built outside Material
/// components. Keeping these values together prevents individual features
/// from slowly drifting into slightly different spacings and icon sizes.
const double kSpaceXs = 4;
const double kSpaceSm = 8;
const double kSpaceMd = 12;
const double kSpaceLg = 16;
const double kCompactIconSize = 20;
const double kStandardIconSize = 24;

/// [kRadius] as a [Radius]/[BorderRadius] for the many hand-rolled containers
/// that can't read a shape from the theme.
const Radius kRadiusCorner = Radius.circular(kRadius);
const BorderRadius kBorderRadius = BorderRadius.all(kRadiusCorner);

/// A [RoundedRectangleBorder] at [kRadius], for widgets whose `shape` we set.
const RoundedRectangleBorder kRoundedShape = RoundedRectangleBorder(
  borderRadius: kBorderRadius,
);

/// The quietest line in the app. Chrome seams, the top bar's underline, the
/// sidebar and drawer edges, the separators inside them, should read as a
/// change of surface rather than a drawn rule — but only just: at half
/// strength these lines disappeared entirely on a laptop screen, taking the
/// app's structure with them.
Color hairlineColor(ColorScheme scheme) =>
    scheme.outlineVariant.withValues(alpha: 0.8);

/// The fill behind a board column: the trough of the depth model at the top of
/// this file. Derived from the canvas rather than fixed, so it keeps the
/// accent's tint and stays one step below whatever the canvas currently is.
Color boardColumnColor(ColorScheme scheme) {
  final canvas = HSLColor.fromColor(scheme.surfaceDim);
  return canvas
      .withLightness((canvas.lightness - 0.04).clamp(0.0, 1.0))
      .toColor();
}

/// The edge of a board column. Quieter than [hairlineColor] would be here: the
/// fill already carries the shape, so the border only has to keep the corner
/// crisp instead of drawing the column a second time. It steps away from the
/// trough in whichever direction has room left — down in light, up in dark,
/// where the trough is already close to black.
Color boardColumnBorderColor(ColorScheme scheme) {
  final trough = HSLColor.fromColor(boardColumnColor(scheme));
  final step = scheme.brightness == Brightness.light ? -0.05 : 0.06;
  return trough
      .withLightness((trough.lightness + step).clamp(0.0, 1.0))
      .toColor();
}

/// How much of the accent's hue bleeds into the app's neutrals.
///
/// Surfaces are not pure greys: each is the accent's *hue* at a fixed, very
/// low saturation, so a warm accent gives the app warm paper and a cool one
/// gives it cool paper, and every surface moves together when someone changes
/// their accent in Settings. Saturation is pinned here rather than inherited
/// from the seed so that a vivid accent tints the chrome no harder than a
/// muted one does.
const double _neutralTintLight = 0.14;
const double _neutralTintDark = 0.08;

/// Under this, a seed is a grey and `HSLColor` reports a meaningless hue for
/// it. Tinting by that hue would turn the whole app pink.
const double _minTintableSaturation = 0.06;

/// A neutral at [lightness], carrying the accent's hue. See [_neutralTintLight].
Color _neutral(Color seed, double lightness, {required bool light}) {
  final hsl = HSLColor.fromColor(seed);
  final tint = hsl.saturation < _minTintableSaturation
      ? 0.0
      : (light ? _neutralTintLight : _neutralTintDark);
  return hsl.withSaturation(tint).withLightness(lightness).toColor();
}

/// Black or white, whichever the accent can actually carry. A yellow accent
/// takes near-black text; a navy one takes white. Reading it off the fill
/// rather than off the theme is what lets a single rule serve any accent
/// someone picks in Settings.
///
/// Where the two are close (a mid-tone accent clears roughly 4.5:1 either way)
/// white wins, which is the conventional look; ink only takes over when it is
/// clearly the more legible of the two.
Color _onAccent(Color fill) {
  const ink = Color(0xFF1B1A16);
  double contrast(Color a, Color b) {
    final l1 = a.computeLuminance(), l2 = b.computeLuminance();
    return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
  }

  return contrast(ink, fill) > contrast(Colors.white, fill) * 1.2
      ? ink
      : Colors.white;
}

ThemeData buildTheme(Brightness brightness, {Color seed = kDefaultAccent}) {
  final light = brightness == Brightness.light;
  Color neutral(double lightness) => _neutral(seed, lightness, light: light);

  // The canvas: the floor of the depth model above. Everything else is placed
  // relative to it.
  final canvas = neutral(light ? 0.925 : 0.070);
  final surface = light ? Colors.white : neutral(0.125);

  // M3 derives `primary` by dropping the seed to tone 40 (tone 80 in dark) so
  // that accent-coloured *text* clears 4.5:1 on a surface. For a yellow seed
  // that tone is brown, and the app's most prominent control — a filled button
  // — was rendering the brand amber as mud. So the accent gets two roles:
  // `primary` keeps M3's readable tone for text and icons, and
  // `primaryContainer` becomes the accent at full strength, for the places the
  // accent is a *fill* and the text sits on top of it (buttons, the FAB, the
  // avatar, chat bubbles). `secondaryContainer` is the same accent worn quietly
  // — the wash behind a selected row or an active chip.
  final accent = seed;
  final onAccent = _onAccent(accent);
  final accentWash = Color.alphaBlend(
    accent.withValues(alpha: light ? 0.22 : 0.20),
    surface,
  );
  final seeded = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  final scheme = seeded.copyWith(
    primaryContainer: accent,
    onPrimaryContainer: onAccent,
    secondaryContainer: accentWash,
    // A wash is a background, not a container in M3's sense: the text on it is
    // the app's ordinary body colour, at full strength.
    onSecondaryContainer: seeded.onSurface,
    surface: surface,
    surfaceDim: canvas,
    surfaceBright: light ? Colors.white : neutral(0.250),
    surfaceContainerLowest: light ? Colors.white : neutral(0.045),
    surfaceContainerLow: neutral(light ? 0.970 : 0.150),
    surfaceContainer: neutral(light ? 0.947 : 0.175),
    surfaceContainerHigh: neutral(light ? 0.920 : 0.210),
    surfaceContainerHighest: neutral(light ? 0.885 : 0.250),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    // Chrome is a surface, not the canvas: the home screen's hand-rolled top
    // bar has always painted itself `surface`, and every other screen's app
    // bar now matches it, so the band across the top of the app is the same
    // paper everywhere instead of dissolving into the background on some
    // screens and not others.
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    drawerTheme: base.drawerTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      // Material rounds the drawer's trailing edge to 16; that lone big curve
      // reads as a different app next to everything else here. The side gives
      // it the same seam the top bar draws, only the trailing edge is ever
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
    // Everything that floats is a `surface`, the same paper a note card is
    // made of: M3's default puts dialogs on `surfaceContainerHigh`, which in
    // this ladder sits within a couple of units of the canvas and left a
    // dialog looking like a patch of background with a scrim around it.
    dialogTheme: base.dialogTheme.copyWith(
      shape: kRoundedShape,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
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
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
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
    // The app's one loud control, and the only place the accent appears at
    // full strength across a whole shape. It wears `primaryContainer` (see the
    // accent note above) rather than `primary`, so the brand colour arrives as
    // itself instead of as M3's readable-on-white tone of it.
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(kRoundedShape),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.12)
              : scheme.primaryContainer,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.38)
              : scheme.onPrimaryContainer,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? scheme.onPrimaryContainer.withValues(alpha: 0.12)
              : states.contains(WidgetState.hovered)
              ? scheme.onPrimaryContainer.withValues(alpha: 0.08)
              : null,
        ),
      ),
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
    // SegmentedButton defaults to a stadium (pill) shape, square it off.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          kRoundedShape.copyWith(side: BorderSide(color: scheme.outline)),
        ),
      ),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      shape: kRoundedShape,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
    ),
    // Light "elevated toast" snackbars, a raised surface card, not the dark
    // inverse bar, so they read as native to the note cards. showAppSnack
    // (util/snack.dart) fills in a tinted leading icon chip. The outline is
    // what keeps it a card: a toast lands over the canvas *and* over white
    // note cards, so the shadow alone cannot be trusted to draw its edge.
    snackBarTheme: base.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 96, 16),
      width: null,
      elevation: 6,
      backgroundColor: scheme.surface,
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 13.5,
      ),
      actionTextColor: scheme.primary,
      closeIconColor: scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: kBorderRadius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      waitDuration: const Duration(milliseconds: 600),
    ),
  );
}
