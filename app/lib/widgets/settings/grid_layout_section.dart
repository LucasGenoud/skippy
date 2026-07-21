import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';

/// Settings block for the note-grid layout: card density, how wide the centered
/// grid may grow, and a live miniature preview of the two combined.
class GridLayoutSection extends StatelessWidget {
  const GridLayoutSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.grid_view_outlined),
          title: const Text('Grid density'),
          subtitle: Text(settings.gridDensity.blurb),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<GridDensity>(
            segments: [
              for (final density in GridDensity.values)
                ButtonSegment(value: density, label: Text(density.label)),
            ],
            selected: {settings.gridDensity},
            onSelectionChanged: (s) => settings.setGridDensity(s.first),
            showSelectedIcon: false,
          ),
        ),
        const ListTile(
          leading: Icon(Icons.fit_screen_outlined),
          title: Text('Content width'),
          subtitle: Text('How wide the grid grows on large screens'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<GridWidth>(
            segments: [
              for (final width in GridWidth.values)
                ButtonSegment(value: width, label: Text(width.label)),
            ],
            selected: {settings.gridWidth},
            onSelectionChanged: (s) => settings.setGridWidth(s.first),
            showSelectedIcon: false,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: _GridPreview(
            density: settings.gridDensity,
            width: settings.gridWidth,
          ),
        ),
      ],
    );
  }
}

/// A scaled-down illustration of the home grid under the current density +
/// width. The outer frame stands in for a large desktop display; the centered
/// band of cards inside shows how wide the grid grows and how many columns fit.
class _GridPreview extends StatelessWidget {
  final GridDensity density;
  final GridWidth width;

  const _GridPreview({required this.density, required this.width});

  /// A representative large-desktop width the settings map onto for the preview.
  static const double _refScreen = 1920;

  /// Varied heights so a column reads as stacked notes, not a solid bar.
  static const List<double> _heights = [
    0.62,
    1.0,
    0.5,
    0.85,
    0.7,
    0.95,
    0.55,
    0.8,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        // Full width has no cap; clamp everything to the reference screen so the
        // preview stays within its frame.
        final effective = math.min(width.maxWidth, _refScreen);
        final innerW = screenW * (effective / _refScreen);
        final columns = (effective / density.targetWidth)
            .floor()
            .clamp(2, density.maxColumns);
        const gap = 4.0;
        const unit = 22.0;

        Widget miniCard(double factor) => Container(
          height: unit * factor,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(3),
          ),
        );

        return Container(
          height: 88,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: innerW,
            // Expanded columns divide the band exactly, so sub-pixel rounding
            // can never overflow the row (which a fixed card width would).
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: gap),
                  Expanded(
                    child: Column(
                      children: [
                        miniCard(_heights[(c * 2) % _heights.length]),
                        const SizedBox(height: gap),
                        miniCard(_heights[(c * 2 + 1) % _heights.length]),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
