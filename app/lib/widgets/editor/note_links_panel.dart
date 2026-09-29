import 'package:flutter/material.dart';

import '../../models/note.dart';
import '../../state/note_links.dart';
import '../../theme.dart';

const _pickerMaxHeight = 220.0;

/// Notes to link to while `[[` is being typed, docked above the editor's
/// bottom bar so it stays clear of the keyboard.
class NoteLinkPicker extends StatelessWidget {
  final List<Note> notes;
  final String query;
  final ValueChanged<Note> onPick;

  const NoteLinkPicker({
    super.key,
    required this.notes,
    required this.query,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Taps here must not count as tapping outside the body field, or the
    // field would drop focus before the pick lands.
    return TextFieldTapRegion(
      child: Material(
        key: const Key('note-link-picker'),
        color: scheme.surfaceContainerHigh,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _pickerMaxHeight),
          child: notes.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    query.trim().isEmpty
                        ? 'No notes to link to'
                        : 'No notes match "${query.trim()}"',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView(
                  primary: false,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final note in notes)
                      InkWell(
                        key: ValueKey('note-link-option-${note.id}'),
                        onTap: () => onPick(note),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.link,
                                size: 17,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  noteLinkTitle(note),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// One end of a link, as the editor lists it.
class LinkedNoteRef {
  final String id;
  final String title;

  /// False when the note is not reachable from this account (deleted, or in
  /// a workspace the viewer is not part of); it shows but cannot open.
  final bool reachable;

  const LinkedNoteRef({
    required this.id,
    required this.title,
    required this.reachable,
  });
}

/// The notes this one links to and the notes linking to it.
class NoteLinksSection extends StatelessWidget {
  final List<LinkedNoteRef> outgoing;
  final List<LinkedNoteRef> incoming;
  final ValueChanged<String> onOpen;

  const NoteLinksSection({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget group(String label, IconData icon, List<LinkedNoteRef> refs) =>
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: sectionLabelStyle(theme)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ref in refs)
                    ActionChip(
                      key: ValueKey('$label-${ref.id}'),
                      avatar: Icon(icon, size: 16),
                      label: Text(ref.title),
                      visualDensity: VisualDensity.compact,
                      onPressed: ref.reachable ? () => onOpen(ref.id) : null,
                    ),
                ],
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (outgoing.isNotEmpty) group('LINKS', Icons.north_east, outgoing),
        if (incoming.isNotEmpty)
          group('LINKED FROM', Icons.south_west, incoming),
      ],
    );
  }
}
