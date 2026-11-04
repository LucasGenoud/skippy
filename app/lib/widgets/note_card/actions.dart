part of '../note_card.dart';

// The hover row of actions along a card's footer, and its overflow menu.

/// Pointer-only card actions. The card always reserves this footer on desktop
/// so revealing the controls never shifts text, images, or neighboring tiles.
/// The card's hover row and its overflow menu. What needs the tile itself
/// (its reminder guard, its rect, its swipe) arrives as a callback; the rest
/// runs here through the shared note actions.
class _NoteActions extends StatelessWidget {
  /// Keeps a hovered button's fill off the rule above the row.
  static const double _ruleGap = 6;

  final Note note;
  final bool rewriting;

  /// Opens the column picker. The board's move gesture in v1, and the
  /// keyboard/screen-reader path on every platform.
  final bool showMoveToStage;
  final VoidCallback onReminder;
  final VoidCallback onImage;
  final VoidCallback onArchive;
  final VoidCallback onDuplicate;
  final VoidCallback onMenuOpened;
  final VoidCallback onMenuClosed;

  const _NoteActions({
    required this.note,
    required this.rewriting,
    required this.showMoveToStage,
    required this.onReminder,
    required this.onImage,
    required this.onArchive,
    required this.onDuplicate,
    required this.onMenuOpened,
    required this.onMenuClosed,
  });

  /// Runs [action] once the menu has finished closing, so a sheet or dialog
  /// does not open underneath it.
  static Future<void> _afterMenu(
    BuildContext context,
    void Function() action,
  ) async {
    await Motion.waitForMenuDismissal(context);
    if (context.mounted) action();
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) => IconButton(
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    iconSize: 19,
    icon: Icon(icon),
    color: color,
    tooltip: tooltip,
    onPressed: onPressed,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.read<NotesStore>();
    // Rebuild when the workspace's AI changes; the availability reads it.
    context.select<NotesStore, WorkspaceAi>((s) => s.aiIn(note.workspaceId));
    final can = NoteAvailability(store, note);
    final hasReminder = context.select<SettingsStore, bool>(
      (settings) =>
          note.reminderAt != null ||
          settings.locationReminderForNote(note.id) != null,
    );
    return Container(
      key: ValueKey('note-actions-${note.id}'),
      padding: const EdgeInsets.only(top: _ruleGap),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _button(
            icon: Icons.palette_outlined,
            tooltip: 'Note color',
            onPressed: () => ColorPickerSheet.show(
              context,
              selected: () => store.noteById(note.id)?.color ?? 'default',
              onSelect: (color) => store.setColor(note.id, color),
            ),
          ),
          _button(
            icon: Icons.label_outline,
            tooltip: 'Add label',
            onPressed: () => LabelsSheet.show(context, note.id),
          ),
          _button(
            icon: !hasReminder
                ? Icons.notification_add_outlined
                : Icons.notifications_active_outlined,
            tooltip: !hasReminder ? 'Add reminder' : 'Edit reminder',
            onPressed: onReminder,
          ),
          _button(
            icon: Icons.image_outlined,
            tooltip: 'Add image',
            onPressed: onImage,
          ),
          _button(
            icon: note.archived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
            tooltip: note.archived ? 'Unarchive note' : 'Archive note',
            onPressed: onArchive,
          ),
          MenuAnchor(
            onOpen: onMenuOpened,
            onClose: onMenuClosed,
            builder: (context, controller, child) => _button(
              icon: Icons.more_vert,
              tooltip: 'More note options',
              color: scheme.onSurfaceVariant,
              onPressed: controller.isOpen ? controller.close : controller.open,
            ),
            menuChildren: [
              if (can.canRewrite) ...[
                SubmenuButton(
                  leadingIcon: const Icon(Icons.auto_fix_high_outlined),
                  menuChildren: [
                    for (final task in can.rewriteTasks)
                      MenuItemButton(
                        onPressed: rewriting
                            ? null
                            : () => rewriteWithAi(store, note.id, task),
                        child: Text(task.name),
                      ),
                  ],
                  child: const Text('AI edit'),
                ),
                const Divider(height: 1),
              ],
              MenuItemButton(
                leadingIcon: const Icon(Icons.person_add_alt_outlined),
                onPressed: () => _afterMenu(
                  context,
                  () => shareNote(context, store.noteById(note.id)),
                ),
                child: const Text('Share'),
              ),
              // Both live in the menu rather than the action row: six
              // controls already share a card's width.
              MenuItemButton(
                leadingIcon: const Icon(Icons.content_copy_outlined),
                onPressed: can.canCopy ? () => copyNoteText(note) : null,
                child: const Text('Copy to clipboard'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.copy_all_outlined),
                onPressed: can.canDuplicate ? onDuplicate : null,
                child: const Text('Duplicate'),
              ),
              if (showMoveToStage && can.canMoveToStage)
                MenuItemButton(
                  leadingIcon: const Icon(Icons.view_kanban_outlined),
                  onPressed: () => _afterMenu(
                    context,
                    () => MoveToStageSheet.show(context, note.id),
                  ),
                  child: const Text('Move to column'),
                ),
              if (can.canMoveToCollection)
                MenuItemButton(
                  leadingIcon: const Icon(Icons.folder_outlined),
                  onPressed: () => _afterMenu(context, () async {
                    final target = await CollectionPicker.show(
                      context,
                      note.workspaceId,
                    );
                    if (target != null) {
                      store.moveToCollection(note.id, target);
                    }
                  }),
                  child: const Text('Move to collection'),
                ),
              if (can.canMoveToWorkspace)
                MenuItemButton(
                  leadingIcon: const Icon(Icons.drive_file_move_outlined),
                  onPressed: () => _afterMenu(
                    context,
                    () => MoveToWorkspaceSheet.show(context, note.id),
                  ),
                  child: const Text('Move to workspace'),
                ),
              MenuItemButton(
                leadingIcon: Icon(
                  Icons.delete_outline,
                  color: can.canTrash ? scheme.error : null,
                ),
                onPressed: can.canTrash
                    ? () => trashNote(store, note.id)
                    : null,
                child: Text(
                  can.canTrash ? 'Move to Trash' : 'Only the owner can delete',
                  style: can.canTrash ? TextStyle(color: scheme.error) : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
