part of '../note_card.dart';

// Labels as a card draws them: the chips in the body, and the footer row
// that trades places with the hover actions.

/// How a card draws a label or its collection marker: a name, a hex colour and
/// an icon key, with blank ones read as unset. A record, so `select` compares
/// it by value.
typedef _Tag = ({String name, String? color, String? icon});

_Tag _tagOf(String name, String? color, String? icon) =>
    (name: name, color: _unlessBlank(color), icon: _unlessBlank(icon));

String? _unlessBlank(String? value) =>
    value == null || value.isEmpty ? null : value;

/// The labels a card shows, sorted by name. Equal when the labels are, so a
/// card selecting these rebuilds only when one of its own labels changes; a
/// freshly built List never equals the previous one.
class _CardLabels {
  final List<_Tag> tags;

  const _CardLabels(this.tags);

  factory _CardLabels.of(NotesStore store, Note note) => _CardLabels(
    [
      for (final id in note.labelIds)
        if (store.labelById(id) case final Label label)
          _tagOf(label.name, label.color, label.icon),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
  );

  @override
  bool operator ==(Object other) =>
      other is _CardLabels && listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hashAll(tags);
}

/// The otherwise reserved desktop footer shows labels at rest. The action row
/// replaces it on hover without shifting a card.
class _NoteFooterLabels extends StatelessWidget {
  final Note note;
  final bool visible;
  final double bottomInset;
  const _NoteFooterLabels({
    required this.note,
    required this.visible,
    this.bottomInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final labels = context
        .select<NotesStore, _CardLabels>((s) => _CardLabels.of(s, note))
        .tags;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 8 + bottomInset,
      height: 40,
      child: AnimatedOpacity(
        key: ValueKey('note-footer-labels-${note.id}'),
        opacity: visible ? 1 : 0,
        duration: Motion.fast,
        curve: Motion.standard,
        child: IgnorePointer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const markerWidth = 24.0;
              const markerGap = 6.0;
              final fullLabelsWidth = labels.isEmpty
                  ? 0.0
                  : labels
                            .map((tag) => _labelChipWidth(context, tag))
                            .reduce((a, b) => a + markerGap + b) +
                        1;
              final compact = fullLabelsWidth > constraints.maxWidth;
              final markerSlots =
                  ((constraints.maxWidth + markerGap) /
                          (markerWidth + markerGap))
                      .floor();
              final showOverflow =
                  compact && markerSlots > 0 && labels.length > markerSlots;
              final visibleLabelCount = compact
                  ? (markerSlots - (showOverflow ? 1 : 0)).clamp(
                      0,
                      labels.length,
                    )
                  : labels.length;

              return Align(
                alignment: Alignment.centerLeft,
                child: compact
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var index = 0;
                            index < visibleLabelCount;
                            index++
                          ) ...[
                            _FooterLabelMarker(
                              tag: labels[index],
                              key: ValueKey(
                                'note-footer-label-marker-${note.id}-$index',
                              ),
                            ),
                            if (index + 1 < visibleLabelCount || showOverflow)
                              const SizedBox(width: markerGap),
                          ],
                          if (showOverflow) const _FooterOverflowMarker(),
                        ],
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var index = 0;
                            index < labels.length;
                            index++
                          ) ...[
                            _LabelChip.of(labels[index]),
                            if (index + 1 < labels.length)
                              const SizedBox(width: markerGap),
                          ],
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  double _textWidth(BuildContext context, String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  double _labelChipWidth(BuildContext context, _Tag tag) {
    // The text width plus the chip's horizontal padding, optional icon and
    // border. This lets the footer switch layouts before RenderFlex overflows.
    return _textWidth(
          context,
          tag.name,
          Theme.of(context).textTheme.labelSmall,
        ) +
        (tag.icon != null || tag.color != null ? 36 : 22);
  }
}

class _FooterLabelMarker extends StatelessWidget {
  final _Tag tag;
  const _FooterLabelMarker({required this.tag, super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tag.name,
      child: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: _chipDecoration(scheme),
        child: Icon(
          labelIconFor(tag.icon),
          size: 13,
          color: PaletteEntry.hexToColor(tag.color) ?? scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A label as a card draws it: a neutral badge, a translucent surface over
/// whatever the card's fill is behind a quiet edge. The label's own colour
/// goes only on its icon or a small square, so a row of chips reads calm and
/// the colour still tells them apart.
BoxDecoration _chipDecoration(ColorScheme scheme) => BoxDecoration(
  borderRadius: kBorderRadius,
  color: scheme.surface.withValues(alpha: 0.7),
  border: Border.all(
    color: Color.lerp(scheme.outlineVariant, scheme.onSurface, 0.06)!,
  ),
);

class _FooterOverflowMarker extends StatelessWidget {
  const _FooterOverflowMarker();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: _chipDecoration(Theme.of(context).colorScheme),
      child: Icon(Icons.more_horiz, size: 16, color: color),
    );
  }
}

class _LabelChip extends StatelessWidget {
  final String name;
  final String? color; // hex, or null for the theme default
  final String? iconKey; // curated icon key, or null for no leading icon

  /// A plain count chip, such as "+2 files".
  const _LabelChip({required this.name}) : color = null, iconKey = null;

  _LabelChip.of(_Tag tag)
    : name = tag.name,
      color = tag.color,
      iconKey = tag.icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = PaletteEntry.hexToColor(color);
    final marked = iconKey != null || tint != null;
    return Container(
      padding: EdgeInsets.only(
        left: marked ? 7 : 10,
        right: 10,
        top: 3,
        bottom: 3,
      ),
      decoration: _chipDecoration(scheme),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconKey != null) ...[
            Icon(
              labelIconFor(iconKey),
              size: 13,
              color: tint ?? scheme.onSurfaceVariant,
            ),
            const SizedBox(width: kSpaceXs),
          ] else if (tint != null) ...[
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
            const SizedBox(width: kSpaceXs),
          ],
          Text(
            name,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurface),
          ),
        ],
      ),
    );
  }
}
