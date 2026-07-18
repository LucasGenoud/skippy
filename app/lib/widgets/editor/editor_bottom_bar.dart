import 'package:flutter/material.dart';

import '../../models/note.dart';

/// The editor's bottom action strip: attachment/metadata buttons on the left,
/// the edited stamp in the middle, undo/redo and the overflow menu on the
/// right. A null callback renders its button disabled.
class EditorBottomBar extends StatelessWidget {
  final bool trashed;
  final bool isOwner;
  final NoteKind kind;
  final String editedStamp;
  final VoidCallback? onPalette;
  final VoidCallback? onLabels;
  final VoidCallback? onReminder;
  final VoidCallback? onImage;
  final VoidCallback? onAttach;
  final VoidCallback? onShare;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;
  final VoidCallback? onHistory;
  final void Function(NoteKind target)? onConvert;

  const EditorBottomBar({
    super.key,
    required this.trashed,
    required this.isOwner,
    required this.kind,
    required this.editedStamp,
    this.onPalette,
    this.onLabels,
    this.onReminder,
    this.onImage,
    this.onAttach,
    this.onShare,
    this.onUndo,
    this.onRedo,
    this.onDelete,
    this.onCopy,
    this.onHistory,
    this.onConvert,
  });

  static const _kindLabels = {
    NoteKind.text: 'Convert to text note',
    NoteKind.checklist: 'Convert to checklist',
    NoteKind.markdown: 'Convert to markdown note',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Note color',
            onPressed: onPalette,
          ),
          IconButton(
            icon: const Icon(Icons.label_outline),
            tooltip: 'Labels',
            onPressed: onLabels,
          ),
          IconButton(
            icon: const Icon(Icons.notification_add_outlined),
            tooltip: 'Remind me',
            onPressed: onReminder,
          ),
          IconButton(
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Add image',
            onPressed: onImage,
          ),
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: 'Attach file',
            onPressed: onAttach,
          ),
          IconButton(
            icon: const Icon(Icons.person_add_alt_outlined),
            tooltip: 'Collaborators',
            onPressed: onShare,
          ),
          // Takes the whole middle band (not a third of it, the way two
          // Spacers flanking a Flexible would) so the stamp isn't needlessly
          // truncated to "Edit…".
          Expanded(
            child: Center(
              child: Text(
                editedStamp,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: onUndo,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: 'Redo',
            onPressed: onRedo,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'delete') onDelete?.call();
              if (value == 'copy') onCopy?.call();
              if (value == 'history') onHistory?.call();
              for (final target in NoteKind.values) {
                if (value == 'convert:${target.name}') onConvert?.call(target);
              }
            },
            itemBuilder: (context) => [
              // Audio notes come from a recording, never a conversion target.
              for (final target in NoteKind.values)
                if (target != kind && target != NoteKind.audio)
                  PopupMenuItem(
                    value: 'convert:${target.name}',
                    enabled: onConvert != null,
                    child: Text(_kindLabels[target]!),
                  ),
              PopupMenuItem(
                value: 'history',
                enabled: onHistory != null,
                child: const Text('Version history'),
              ),
              PopupMenuItem(
                value: 'copy',
                enabled: onCopy != null,
                child: const Text('Make a copy'),
              ),
              if (isOwner)
                PopupMenuItem(
                  value: 'delete',
                  enabled: onDelete != null,
                  child: const Text('Delete'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
