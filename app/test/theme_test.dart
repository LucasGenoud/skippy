import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/theme.dart';

/// WCAG contrast ratio, the measure every threshold below is stated in.
double contrast(Color a, Color b) {
  final l1 = a.computeLuminance(), l2 = b.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

/// The accents someone can actually pick: the default, a dark cool one, and a
/// grey. Every rule here has to hold for all of them, since the surfaces are
/// derived from whichever is chosen.
const seeds = <String, Color>{
  'amber (default)': kDefaultAccent,
  'blue': Color(0xFF1A73E8),
  'grey': Color(0xFF9E9E9E),
};

void main() {
  test('a chosen font sets every text style, none keeps the platform one', () {
    final chosen = buildTheme(Brightness.light, fontFamily: 'Lora');
    expect(chosen.textTheme.bodyMedium?.fontFamily, 'Lora');
    expect(chosen.textTheme.titleSmall?.fontFamily, 'Lora');

    final platform = buildTheme(Brightness.light);
    expect(
      platform.textTheme.bodyMedium?.fontFamily,
      platform.typography.black.bodyMedium?.fontFamily,
    );
  });

  group('the depth model reads', () {
    // The bug this pins: white cards on an F8F9FA canvas differed by 1.04:1
    // and had nothing else to set them apart, so the app looked like one flat
    // sheet. The zinc look keeps the fills close on purpose, so the edge every
    // card draws (`outlineVariant`) is what has to read.
    test('cards separate from the canvas in both brightnesses', () {
      for (final entry in seeds.entries) {
        for (final brightness in Brightness.values) {
          final theme = buildTheme(brightness, seed: entry.value);
          final scheme = theme.colorScheme;
          final where = '${entry.key} / ${brightness.name}';
          expect(
            contrast(scheme.surface, theme.scaffoldBackgroundColor),
            greaterThan(1.02),
            reason: 'fill, $where',
          );
          expect(
            contrast(scheme.outlineVariant, theme.scaffoldBackgroundColor),
            greaterThan(1.1),
            reason: 'edge, $where',
          );
          // The canvas is `surfaceDim`; widgets that need the floor read it
          // from the scheme rather than from the Scaffold.
          expect(scheme.surfaceDim, theme.scaffoldBackgroundColor);
        }
      }
    });

    // A board column has to read as a region cards are dropped into. Which
    // *way* it steps off the canvas is a detail of the theme, since near black
    // there is no room to go darker; that its edge reads against the canvas,
    // and the cards' edges against it, is the rule.
    test('troughs step clear of the canvas, and cards clear of them', () {
      for (final entry in seeds.entries) {
        for (final brightness in Brightness.values) {
          final theme = buildTheme(brightness, seed: entry.value);
          final scheme = theme.colorScheme;
          final trough = boardColumnColor(scheme);
          final border = boardColumnBorderColor(scheme);
          final where = '${entry.key} / ${brightness.name}';
          expect(
            contrast(trough, scheme.surfaceDim),
            greaterThan(1.02),
            reason: 'column vs canvas, $where',
          );
          // A touch under the card edge's 1.1: the column's fill steps off the
          // canvas in the same direction, so the two together carry it.
          expect(
            contrast(border, scheme.surfaceDim),
            greaterThan(1.08),
            reason: 'column edge vs canvas, $where',
          );
          expect(
            contrast(scheme.outlineVariant, trough),
            greaterThan(1.1),
            reason: 'card edge vs column, $where',
          );
          // A border that collapsed to pure black, and later one brighter than
          // the cards inside the column, were both earlier attempts at this.
          expect(border, isNot(const Color(0xFF000000)), reason: where);
          if (brightness == Brightness.dark) {
            expect(
              border.computeLuminance(),
              lessThan(scheme.surface.computeLuminance()),
              reason: 'border must not outshine the cards, $where',
            );
          }
        }
      }
    });
  });

  group('the accent stays legible', () {
    test('an accent fill carries its own on-colour at 4.5:1', () {
      for (final entry in seeds.entries) {
        for (final brightness in Brightness.values) {
          final scheme = buildTheme(brightness, seed: entry.value).colorScheme;
          // primaryContainer is the accent at full strength (buttons, FAB,
          // avatar), so whatever sits on it has to clear body-text contrast.
          expect(
            contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key} / ${brightness.name}',
          );
          // The wash (selected rows, active chips) carries ordinary body text.
          expect(
            contrast(scheme.onSecondaryContainer, scheme.secondaryContainer),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key} / ${brightness.name}',
          );
        }
      }
    });

    test('body text keeps its headroom on every surface', () {
      for (final entry in seeds.entries) {
        for (final brightness in Brightness.values) {
          final scheme = buildTheme(brightness, seed: entry.value).colorScheme;
          for (final surface in [
            scheme.surface,
            scheme.surfaceDim,
            scheme.surfaceContainer,
            scheme.surfaceContainerHighest,
          ]) {
            expect(
              contrast(scheme.onSurface, surface),
              greaterThanOrEqualTo(7),
              reason: '${entry.key} / ${brightness.name}',
            );
            expect(
              contrast(scheme.onSurfaceVariant, surface),
              greaterThanOrEqualTo(4.5),
              reason: '${entry.key} / ${brightness.name}',
            );
          }
        }
      }
    });
  });

  test('a grey accent leaves the neutrals neutral', () {
    // HSLColor reports an arbitrary hue for a grey. Tinting by it would give
    // someone who picked grey a pink app.
    for (final brightness in Brightness.values) {
      final theme = buildTheme(brightness, seed: const Color(0xFF9E9E9E));
      final canvas = theme.scaffoldBackgroundColor;
      expect(canvas.r, canvas.g, reason: brightness.name);
      expect(canvas.g, canvas.b, reason: brightness.name);
    }
  });

  test('a coloured accent does reach the neutrals', () {
    // The counterpart to the rule above: the app is meant to pick up the
    // accent's hue, not to stay clinically grey.
    final canvas = buildTheme(Brightness.light).scaffoldBackgroundColor;
    expect(canvas.r, greaterThan(canvas.b), reason: 'amber warms the canvas');
  });
}
