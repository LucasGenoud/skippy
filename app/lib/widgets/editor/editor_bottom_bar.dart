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

  static const _kindIcons = {
    NoteKind.text: Icons.notes_outlined,
    NoteKind.checklist: Icons.checklist,
    NoteKind.markdown: Icons.data_object,
  };

  /// A menu row with a leading icon so the overflow menu scans at a glance.
  /// [color] tints both icon and label (used to flag the destructive Delete).
  static PopupMenuItem<String> _menuItem({
    required String value,
    required IconData icon,
    required String label,
    required bool enabled,
    Color? color,
  }) {
    return PopupMenuItem(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(label, style: color == null ? null : TextStyle(color: color)),
        ],
      ),
    );
  }

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
                  _menuItem(
                    value: 'convert:${target.name}',
                    icon: _kindIcons[target]!,
                    label: _kindLabels[target]!,
                    enabled: onConvert != null,
                  ),
              const PopupMenuDivider(),
              _menuItem(
                value: 'history',
                icon: Icons.history,
                label: 'Version history',
                enabled: onHistory != null,
              ),
              _menuItem(
                value: 'copy',
                icon: Icons.copy_all_outlined,
                label: 'Make a copy',
                enabled: onCopy != null,
              ),
              if (isOwner)
                _menuItem(
                  value: 'delete',
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  enabled: onDelete != null,
                  color: scheme.error,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
