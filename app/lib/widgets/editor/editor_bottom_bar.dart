import 'package:flutter/material.dart';

import '../form_dialog.dart';

/// The editor's bottom action strip: everything that puts something *into* the
/// note on the left, the edited stamp in the middle, undo/redo on the right.
/// A null callback renders its button disabled.
///
/// Managing the note itself — sharing, filing, converting, deleting — lives in
/// the app bar's `NoteActionsButton` instead. The two bars are split by intent,
/// which keeps either menu short enough to read without a second level.
class EditorBottomBar extends StatelessWidget {
  final bool trashed;
  final String editedStamp;
  final VoidCallback? onPalette;
  final VoidCallback? onLabels;
  final VoidCallback? onReminder;
  final VoidCallback? onImage;
  final VoidCallback? onAttach;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  const EditorBottomBar({
    super.key,
    required this.trashed,
    required this.editedStamp,
    this.onPalette,
    this.onLabels,
    this.onReminder,
    this.onImage,
    this.onAttach,
    this.onUndo,
    this.onRedo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Seven 48 px targets need 336 px, so every phone down to 360 keeps the
        // whole compose row in reach. Below that the two insert actions fold
        // into one "Add to note" button — a single, predictable category rather
        // than a general-purpose overflow.
        final veryNarrow = constraints.maxWidth < 360;
        final wide = constraints.maxWidth >= 600;

        Future<void> showInsertActions() async {
          final action = await showAdaptiveSelectionSurface<String>(
            context,
            builder: (context) => SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: const Text('Add image'),
                    enabled: onImage != null,
                    onTap: () => Navigator.pop(context, 'image'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.attach_file),
                    title: const Text('Attach file'),
                    enabled: onAttach != null,
                    onTap: () => Navigator.pop(context, 'attach'),
                  ),
                ],
              ),
            ),
          );
          if (action == 'image') onImage?.call();
          if (action == 'attach') onAttach?.call();
        }

        Widget action({
          required IconData icon,
          required String tooltip,
          required VoidCallback? onPressed,
        }) => IconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              action(
                icon: Icons.palette_outlined,
                tooltip: 'Note color',
                onPressed: onPalette,
              ),
              action(
                icon: Icons.label_outline,
                tooltip: 'Labels',
                onPressed: onLabels,
              ),
              action(
                icon: Icons.notification_add_outlined,
                tooltip: 'Remind me',
                onPressed: onReminder,
              ),
              if (veryNarrow)
                action(
                  icon: Icons.add_circle_outline,
                  tooltip: 'Add to note',
                  // Nothing to insert into a trashed note.
                  onPressed: onImage == null && onAttach == null
                      ? null
                      : showInsertActions,
                )
              else ...[
                action(
                  icon: Icons.image_outlined,
                  tooltip: 'Add image',
                  onPressed: onImage,
                ),
                action(
                  icon: Icons.attach_file,
                  tooltip: 'Attach file',
                  onPressed: onAttach,
                ),
              ],
              if (wide)
                // Takes the whole middle band (not a third of it, the way two
                // Spacers flanking a Flexible would) so the stamp isn't
                // needlessly truncated to "Edit…".
                Expanded(
                  child: Center(
                    child: Text(
                      editedStamp,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              // Editing should never require opening a menu, including on the
              // smallest phones.
              action(icon: Icons.undo, tooltip: 'Undo', onPressed: onUndo),
              action(icon: Icons.redo, tooltip: 'Redo', onPressed: onRedo),
            ],
          ),
        );
      },
    );
  }
}
