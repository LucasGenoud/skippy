import 'package:flutter/material.dart';

import '../../theme.dart';

/// The history popup that hangs under the row being typed into, offering
/// items this note has had checked off before. Anchored with a [LayerLink] so
/// it follows its row as the list moves.
class ChecklistSuggestions extends StatelessWidget {
  /// The anchor of the row the popup belongs to.
  final LayerLink link;
  final List<String> suggestions;

  /// What has been typed so far: the part of each suggestion it matches is
  /// bolded.
  final String query;

  /// The popup is rendered in an overlay, but remains beneath the editor's
  /// PrimaryScrollController in the widget tree. Its own controller keeps
  /// wheel/trackpad input scrolling the suggestions, never the note.
  final ScrollController scrollController;
  final ValueChanged<String> onPick;

  const ChecklistSuggestions({
    super.key,
    required this.link,
    required this.suggestions,
    required this.query,
    required this.scrollController,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CompositedTransformFollower(
      link: link,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(56, 0),
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.topLeft,
        child: TextFieldTapRegion(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 288),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(kRadius),
              color: scheme.surfaceContainerHigh,
              clipBehavior: Clip.antiAlias,
              child: ListView(
                key: const Key('checklist-suggestions'),
                controller: scrollController,
                primary: false,
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  for (final suggestion in suggestions)
                    InkWell(
                      onTap: () => onPick(suggestion),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.history,
                              size: 17,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _BoldMatch(text: suggestion, query: query),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Chi" typed over "Chili peppers" renders **Chi**li peppers.
class _BoldMatch extends StatelessWidget {
  final String text;
  final String query;

  const _BoldMatch({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final q = query.toLowerCase();
    final index = q.isEmpty ? -1 : text.toLowerCase().indexOf(q);
    if (index < 0) {
      return Text(
        text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, index)),
          TextSpan(
            text: text.substring(index, index + q.length),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: text.substring(index + q.length)),
        ],
      ),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
