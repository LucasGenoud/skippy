import 'package:flutter/material.dart';

import '../../models/note.dart';
import '../../util/motion.dart';

/// The editor's bottom action strip: attachment/metadata buttons on the left,
/// the edited stamp in the middle, undo/redo and the overflow menu on the
/// right. A null callback renders its button disabled.
class EditorBottomBar extends StatelessWidget {
  final bool trashed;
  final bool isOwner;
  final bool archived;
  final NoteKind kind;
  final String editedStamp;
  final VoidCallback? onPalette;
  final VoidCallback? onLabels;
  final VoidCallback? onReminder;
  final VoidCallback? onImage;
  final VoidCallback? onAttach;
  final VoidCallback? onShare;
  final VoidCallback? onArchive;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;

  /// File the note in another workspace. Null when the viewer doesn't own it,
  /// or there is nowhere else to put it.
  final VoidCallback? onMoveToWorkspace;

  /// Open the column picker. On a phone the board opens a note full-screen,
  /// which puts the card, and its drag gesture, out of reach; this is the
  /// way back to the board without closing the note first.
  final VoidCallback? onMoveToStage;
  final VoidCallback? onCopyToClipboard;
  final VoidCallback? onHistory;
  final void Function(NoteKind target)? onConvert;
  final ValueChanged<NoteRewriteMode>? onRewrite;
  final bool rewriting;

  const EditorBottomBar({
    super.key,
    required this.trashed,
    required this.isOwner,
    required this.archived,
    required this.kind,
    required this.editedStamp,
    this.onPalette,
    this.onLabels,
    this.onReminder,
    this.onImage,
    this.onAttach,
    this.onShare,
    this.onArchive,
    this.onUndo,
    this.onRedo,
    this.onDelete,
    this.onDuplicate,
    this.onMoveToWorkspace,
    this.onMoveToStage,
    this.onCopyToClipboard,
    this.onHistory,
    this.onConvert,
    this.onRewrite,
    this.rewriting = false,
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
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: color == null ? null : TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Future<void> handleMenuSelection(String value) async {
      const routeActions = {
        'image',
        'reminder',
        'attach',
        'share',
        'archive',
        'delete',
        'move',
        'stage',
        'history',
      };
      if (routeActions.contains(value)) {
        await Motion.waitForMenuDismissal(context);
        if (!context.mounted) return;
      }
      if (value == 'image') onImage?.call();
      if (value == 'reminder') onReminder?.call();
      if (value == 'attach') onAttach?.call();
      if (value == 'share') onShare?.call();
      if (value == 'archive') onArchive?.call();
      if (value == 'delete') onDelete?.call();
      if (value == 'duplicate') onDuplicate?.call();
      if (value == 'move') onMoveToWorkspace?.call();
      if (value == 'stage') onMoveToStage?.call();
      if (value == 'clipboard') onCopyToClipboard?.call();
      if (value == 'history') onHistory?.call();
      if (value == 'concise') onRewrite?.call(NoteRewriteMode.concise);
      if (value == 'grammar') onRewrite?.call(NoteRewriteMode.grammar);
      for (final target in NoteKind.values) {
        if (value == 'convert:${target.name}') onConvert?.call(target);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Nine standard 48 px targets don't fit on a phone. Keep the common
        // note actions in reach and place the rest in More, where they retain
        // their full-size, accessible menu targets instead of overflowing.
        final compact = constraints.maxWidth < 600;
        final veryNarrow = constraints.maxWidth < 360;

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
              if (!veryNarrow)
                action(
                  icon: Icons.notification_add_outlined,
                  tooltip: 'Remind me',
                  onPressed: onReminder,
                ),
              if (!veryNarrow)
                action(
                  icon: Icons.image_outlined,
                  tooltip: 'Add image',
                  onPressed: onImage,
                ),
              if (!compact) ...[
                action(
                  icon: Icons.attach_file,
                  tooltip: 'Attach file',
                  onPressed: onAttach,
                ),
                action(
                  icon: Icons.person_add_alt_outlined,
                  tooltip: 'Collaborators',
                  onPressed: onShare,
                ),
                action(
                  icon: archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  tooltip: archived ? 'Unarchive' : 'Archive',
                  onPressed: onArchive,
                ),
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
                ),
              ] else
                const Spacer(),
              // Editing should never require opening More, including on the
              // smallest phones.
              action(icon: Icons.undo, tooltip: 'Undo', onPressed: onUndo),
              action(icon: Icons.redo, tooltip: 'Redo', onPressed: onRedo),
              PopupMenuButton<String>(
                popUpAnimationStyle: Motion.menuFor(context),
                icon: rewriting
                    ? const SizedBox(
                        key: ValueKey('editor-rewrite-progress'),
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.25),
                      )
                    : const Icon(Icons.more_vert),
                tooltip: 'More',
                onSelected: handleMenuSelection,
                itemBuilder: (context) => [
                  if (compact) ...[
                    if (veryNarrow)
                      _menuItem(
                        value: 'image',
                        icon: Icons.image_outlined,
                        label: 'Add image',
                        enabled: onImage != null,
                      ),
                    if (veryNarrow)
                      _menuItem(
                        value: 'reminder',
                        icon: Icons.notification_add_outlined,
                        label: 'Remind me',
                        enabled: onReminder != null,
                      ),
                    _menuItem(
                      value: 'attach',
                      icon: Icons.attach_file,
                      label: 'Attach file',
                      enabled: onAttach != null,
                    ),
                    _menuItem(
                      value: 'share',
                      icon: Icons.person_add_alt_outlined,
                      label: 'Collaborators',
                      enabled: onShare != null,
                    ),
                    _menuItem(
                      value: 'archive',
                      icon: archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                      label: archived ? 'Unarchive' : 'Archive',
                      enabled: onArchive != null,
                    ),
                    const PopupMenuDivider(),
                  ],
                  if (onRewrite != null && kind != NoteKind.audio) ...[
                    _menuItem(
                      value: 'concise',
                      icon: Icons.auto_fix_high_outlined,
                      label: 'Clean up and make concise',
                      enabled: !rewriting,
                    ),
                    _menuItem(
                      value: 'grammar',
                      icon: Icons.spellcheck_outlined,
                      label: 'Fix grammar and syntax',
                      enabled: !rewriting,
                    ),
                    const PopupMenuDivider(),
                  ],
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
                    value: 'clipboard',
                    icon: Icons.content_copy_outlined,
                    label: 'Copy to clipboard',
                    enabled: onCopyToClipboard != null,
                  ),
                  _menuItem(
                    value: 'duplicate',
                    icon: Icons.copy_all_outlined,
                    label: 'Duplicate',
                    enabled: onDuplicate != null,
                  ),
                  // Above "Move to workspace", in the same order the note
                  // card's menu lists the two.
                  if (onMoveToStage != null)
                    _menuItem(
                      value: 'stage',
                      icon: Icons.view_kanban_outlined,
                      label: 'Move to column',
                      enabled: true,
                    ),
                  if (onMoveToWorkspace != null)
                    _menuItem(
                      value: 'move',
                      icon: Icons.drive_file_move_outlined,
                      label: 'Move to workspace',
                      enabled: true,
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
      },
    );
  }
}
