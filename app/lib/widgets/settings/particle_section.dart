import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';
import '../particle_field.dart';

/// Settings block for the decorative particle layer behind the notes: which
/// effect (if any), how much of it, and a live preview running the real
/// [ParticleField] so the choice is what you actually get.
class ParticleSection extends StatelessWidget {
  const ParticleSection({super.key});

  static IconData iconFor(ParticleEffect effect) => switch (effect) {
    ParticleEffect.none => Icons.block_outlined,
    ParticleEffect.snow => Icons.ac_unit,
    ParticleEffect.glitter => Icons.auto_awesome_outlined,
    ParticleEffect.confetti => Icons.celebration_outlined,
    ParticleEffect.bubbles => Icons.bubble_chart_outlined,
    ParticleEffect.fireflies => Icons.local_fire_department_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final effect = settings.particleEffect;
    final on = effect != ParticleEffect.none;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(iconFor(effect)),
          title: const Text('Background effect'),
          subtitle: Text(effect.blurb),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in ParticleEffect.values)
                ChoiceChip(
                  avatar: Icon(iconFor(option), size: 18),
                  label: Text(option.label),
                  selected: option == effect,
                  onSelected: (_) => settings.setParticleEffect(option),
                ),
            ],
          ),
        ),
        // The intensity control stays visible but inert with the effect off,
        // so the setting doesn't appear and disappear as chips are tapped.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<ParticleIntensity>(
            segments: [
              for (final intensity in ParticleIntensity.values)
                ButtonSegment(
                  value: intensity,
                  label: Text(intensity.label),
                  enabled: on,
                ),
            ],
            selected: {settings.particleIntensity},
            onSelectionChanged: on
                ? (s) => settings.setParticleIntensity(s.first)
                : null,
            showSelectedIcon: false,
          ),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _ParticlePreview(
              effect: effect,
              intensity: settings.particleIntensity,
              palette: [for (final entry in settings.palette) entry.light],
            ),
          ),
      ],
    );
  }
}

/// A card-sized window onto the real effect, drawn over the same canvas color
/// the notes screen uses with a couple of stand-in cards for scale.
class _ParticlePreview extends StatelessWidget {
  final ParticleEffect effect;
  final ParticleIntensity intensity;
  final List<Color> palette;

  const _ParticlePreview({
    required this.effect,
    required this.intensity,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ParticleField(
                effect: effect,
                intensity: intensity,
                palette: palette,
                densityBoost: 4,
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 16, 28, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final height in const [78.0, 50.0, 96.0])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Container(
                            height: height,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
