import 'package:flutter/material.dart';

import '../../models/note.dart';
import '../form_dialog.dart';
import '../../theme.dart';
import '../app_icon_button.dart';
import '../menu_label.dart';
import '../move_note_sheet.dart';

/// Everything you do *to* a note, as opposed to what you put *into* it.
///
/// The editor has two action surfaces and they are split by intent rather than
/// by depth: the bottom bar composes (colour, labels, reminder, image, file)
/// and this app-bar menu manages (share, file, convert, delete). An earlier
/// design nested the rarer half of one combined menu behind "More note
/// options", which asked the reader to guess whether a thing like "Move to
/// column" counted as advanced, and turned a two-tap job into a hunt.
///
/// So the sheet stays one level, ordered by how often each thing is reached
/// for:
///
///   [Copy] [Find] [Share] [Archive] [Delete]   one tap, same place every time
///   Move to…                                   column / collection / workspace
///   Version history · Duplicate · Home Screen
///   Turn into   (chips)
///   Rewrite     (chips)
///
/// The three kinds of move are tabs of one picker ([MoveNoteSheet]) rather
/// than three rows, and families of siblings (rewrites, conversions) are chip
/// rows, which is what keeps it short on a phone.
class NoteActionsButton extends StatelessWidget {
  final bool isOwner;
  final NoteKind kind;

  /// Heads the sheet, so it is clear which note the actions act on. Null for
  /// an untitled note.
  final String? noteTitle;
  final VoidCallback? onFind;
  final VoidCallback? onCopy;
  final VoidCallback? onArchive;

  /// Whether [onArchive] unarchives, which only changes its wording.
  final bool archived;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;

  /// Where this note can be moved, in tab order; [onMove] opens the picker on
  /// the one given.
  final List<NoteMoveTarget> moveTargets;
  final ValueChanged<NoteMoveTarget>? onMove;
  final VoidCallback? onHistory;
  final VoidCallback? onAddToHomeScreen;
  final void Function(NoteKind target)? onConvert;
  final ValueChanged<NoteRewriteTask>? onRewrite;
  final List<NoteRewriteTask> rewriteTasks;
  final int gridSpan;
  final ValueChanged<int>? onGridSpan;

  /// Swaps the trigger for a spinner while an AI rewrite is in flight, and
  /// disables re-running one from the sheet.
  final bool rewriting;

  const NoteActionsButton({
    super.key,
    required this.isOwner,
    required this.kind,
    this.noteTitle,
    this.onFind,
    this.onCopy,
    this.onArchive,
    this.archived = false,
    this.onShare,
    this.onDelete,
    this.onDuplicate,
    this.moveTargets = const [],
    this.onMove,
    this.onHistory,
    this.onAddToHomeScreen,
    this.onConvert,
    this.onRewrite,
    this.rewriteTasks = kDefaultNoteRewriteTasks,
    this.gridSpan = 1,
    this.onGridSpan,
    this.rewriting = false,
  });

  /// Chip labels: the heading above them already says "Turn into", so the
  /// chips name only the destination.
  static const _kindLabels = {
    NoteKind.text: 'Text',
    NoteKind.checklist: 'Checklist',
    NoteKind.markdown: 'Markdown',
  };

  static const _kindIcons = {
    NoteKind.text: Icons.notes_outlined,
    NoteKind.checklist: Icons.checklist,
    NoteKind.markdown: Icons.data_object,
  };

  /// Audio notes come from a recording, so they are convertible away from but
  /// never a conversion target.
  List<NoteKind> get _convertTargets => onConvert == null
      ? const []
      : [
          for (final target in NoteKind.values)
            if (target != kind && target != NoteKind.audio) target,
        ];

  bool get _offersRewrite =>
      onRewrite != null && rewriteTasks.isNotEmpty && kind != NoteKind.audio;

  bool get _offersMove => onMove != null && moveTargets.isNotEmpty;

  List<_NoteAction> _quick(ColorScheme scheme) => [
    if (onCopy != null)
      const _NoteAction(
        value: 'copy',
        icon: Icons.content_copy_outlined,
        label: 'Copy',
        hint: 'Copy to clipboard',
      ),
    if (onFind != null)
      const _NoteAction(
        value: 'find',
        icon: Icons.search,
        label: 'Find',
        hint: 'Find in note',
      ),
    if (onShare != null)
      const _NoteAction(
        value: 'share',
        icon: Icons.person_add_alt_outlined,
        label: 'Share',
        hint: 'Collaborators',
      ),
    if (onArchive != null)
      archived
          ? const _NoteAction(
              value: 'archive',
              icon: Icons.unarchive_outlined,
              label: 'Unarchive',
              hint: 'Back to your notes',
            )
          : const _NoteAction(
              value: 'archive',
              icon: Icons.archive_outlined,
              label: 'Archive',
              hint: 'Out of the way, kept',
            ),
    if (isOwner && onDelete != null)
      _NoteAction(
        value: 'delete',
        icon: Icons.delete_outline,
        label: 'Delete',
        hint: 'Move to trash',
        color: scheme.error,
      ),
  ];

  List<_NoteAction> get _rows => [
    if (_offersMove)
      moveTargets.length == 1
          ? _NoteAction(
              value: 'move:${moveTargets.single.name}',
              icon: _moveIcon(moveTargets.single),
              label: 'Move to ${moveTargets.single.label.toLowerCase()}',
              hint: _moveHint(moveTargets.single),
            )
          : _NoteAction(
              value: 'move:${moveTargets.first.name}',
              icon: Icons.drive_file_move_outlined,
              label: 'Move to…',
              hint: moveTargets.map((t) => t.label).join(', '),
            ),
    if (onHistory != null)
      const _NoteAction(
        value: 'history',
        icon: Icons.history,
        label: 'Version history',
        hint: 'Restore an earlier copy',
      ),
    if (onDuplicate != null)
      const _NoteAction(
        value: 'duplicate',
        icon: Icons.copy_all_outlined,
        label: 'Duplicate',
        hint: 'Make a copy',
      ),
    // Only where the device has a home screen to put it on.
    if (onAddToHomeScreen != null)
      const _NoteAction(
        value: 'homescreen',
        icon: Icons.widgets_outlined,
        label: 'Add to Home Screen',
        hint: 'As a widget',
      ),
  ];

  static IconData _moveIcon(NoteMoveTarget target) => switch (target) {
    NoteMoveTarget.stage => Icons.view_kanban_outlined,
    NoteMoveTarget.collection => Icons.folder_outlined,
    NoteMoveTarget.workspace => Icons.drive_file_move_outlined,
  };

  static String _moveHint(NoteMoveTarget target) => switch (target) {
    NoteMoveTarget.stage => 'Another column on this board',
    NoteMoveTarget.collection => 'Within this workspace',
    NoteMoveTarget.workspace => 'To another workspace',
  };

  void _dispatch(String value) {
    if (value == 'find') onFind?.call();
    if (value == 'copy') onCopy?.call();
    if (value == 'archive') onArchive?.call();
    if (value == 'share') onShare?.call();
    if (value == 'delete') onDelete?.call();
    if (value == 'duplicate') onDuplicate?.call();
    if (value == 'history') onHistory?.call();
    if (value == 'homescreen') onAddToHomeScreen?.call();
    for (final target in NoteMoveTarget.values) {
      if (value == 'move:${target.name}') onMove?.call(target);
    }
    if (value.startsWith('rewrite:')) {
      final id = value.substring('rewrite:'.length);
      for (final task in rewriteTasks) {
        if (task.id == id) onRewrite?.call(task);
      }
    }
    if (value.startsWith('span:')) {
      onGridSpan?.call(int.parse(value.substring('span:'.length)));
    }
    for (final target in NoteKind.values) {
      if (value == 'convert:${target.name}') onConvert?.call(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quick = _quick(Theme.of(context).colorScheme);
    final rows = _rows;
    // A phone's grid is two columns wide, so a choice of card width there
    // would mostly do nothing; it stays on wider windows.
    final offersGridSpan = onGridSpan != null && !isNarrowScreen(context);
    final empty =
        quick.isEmpty &&
        rows.isEmpty &&
        _convertTargets.isEmpty &&
        !_offersRewrite &&
        !offersGridSpan;
    return AppIconButton(
      icon: rewriting
          ? const SizedBox(
              key: ValueKey('editor-rewrite-progress'),
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.25),
            )
          : const Icon(Icons.more_vert),
      tooltip: 'Note actions',
      onPressed: empty
          ? null
          : () async {
              // The surface already waits out its own dismissal before
              // returning, so an action that opens another route never
              // overlaps this one on the way out.
              final action = await showAdaptiveSelectionSurface<String>(
                context,
                maxWidth: 440,
                isScrollControlled: true,
                builder: (context) => _NoteActionsSheet(
                  title: noteTitle,
                  quick: quick,
                  rows: rows,
                  convertTargets: _convertTargets,
                  offersRewrite: _offersRewrite,
                  rewriteTasks: rewriteTasks,
                  rewriting: rewriting,
                  gridSpan: gridSpan,
                  offersGridSpan: offersGridSpan,
                ),
              );
              if (action != null) _dispatch(action);
            },
    );
  }

  static Widget _kindChip(BuildContext context, NoteKind target) => ActionChip(
    avatar: Icon(_kindIcons[target]!, size: 18),
    label: Text(_kindLabels[target]!),
    onPressed: () => Navigator.pop(context, 'convert:${target.name}'),
  );
}

class _NoteActionsSheet extends StatelessWidget {
  final String? title;
  final List<_NoteAction> quick;
  final List<_NoteAction> rows;
  final List<NoteKind> convertTargets;
  final bool offersRewrite;
  final List<NoteRewriteTask> rewriteTasks;
  final bool rewriting;
  final int gridSpan;
  final bool offersGridSpan;

  const _NoteActionsSheet({
    required this.title,
    required this.quick,
    required this.rows,
    required this.convertTargets,
    required this.offersRewrite,
    required this.rewriteTasks,
    required this.rewriting,
    required this.gridSpan,
    required this.offersGridSpan,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // Hugs its content, and scrolls rather than growing into a near
        // full-screen destination on a note that offers everything.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  (title?.trim().isNotEmpty ?? false)
                      ? title!.trim()
                      : 'Note actions',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (quick.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      for (final (i, action) in quick.indexed) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(child: _QuickAction(action: action)),
                      ],
                    ],
                  ),
                ),
              for (final row in rows)
                ListTile(
                  key: ValueKey('note-action-${row.value}'),
                  leading: Icon(row.icon, color: row.color),
                  title: MenuLabel(row.label, hint: row.hint, color: row.color),
                  onTap: () => Navigator.pop(context, row.value),
                ),
              if (offersRewrite || convertTargets.isNotEmpty || offersGridSpan)
                const Divider(height: 24),
              if (convertTargets.isNotEmpty)
                _ChipRow(
                  title: 'Turn into',
                  chips: [
                    for (final target in convertTargets)
                      NoteActionsButton._kindChip(context, target),
                  ],
                ),
              if (offersRewrite)
                _ChipRow(
                  title: 'Rewrite with AI',
                  chips: [
                    for (final task in rewriteTasks)
                      ActionChip(
                        avatar: const Icon(
                          Icons.auto_fix_high_outlined,
                          size: 18,
                        ),
                        label: Text(task.name),
                        onPressed: rewriting
                            ? null
                            : () =>
                                  Navigator.pop(context, 'rewrite:${task.id}'),
                      ),
                  ],
                ),
              if (offersGridSpan)
                _ChipRow(
                  title: 'Card width',
                  chips: [
                    for (var span = 1; span <= 3; span++)
                      ChoiceChip(
                        label: Text(span == 1 ? 'Standard' : '$span columns'),
                        selected: gridSpan == span,
                        onSelected: (_) => Navigator.pop(context, 'span:$span'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the sheet's most-used actions: an icon over a one-word label, in a
/// row of equal tiles. The tooltip and screen reader get the full name.
class _QuickAction extends StatelessWidget {
  final _NoteAction action;

  const _QuickAction({required this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = action.color ?? scheme.onSurface;
    return Tooltip(
      message: action.hint,
      child: Material(
        key: ValueKey('note-action-${action.value}'),
        color: scheme.surfaceContainerHigh,
        borderRadius: kBorderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pop(context, action.value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(action.icon, color: color, size: 22),
                const SizedBox(height: 6),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A family of related choices as one row of chips, so it costs one line
/// instead of one line per option.
class _ChipRow extends StatelessWidget {
  final String title;
  final List<Widget> chips;

  const _ChipRow({required this.title, required this.chips});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: kSpaceSm),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }
}

class _NoteAction {
  final String value;
  final IconData icon;
  final String label;

  /// What the action does, in a few grey words beside the label.
  final String hint;

  /// Tints icon and label, used to flag the destructive Delete.
  final Color? color;

  const _NoteAction({
    required this.value,
    required this.icon,
    required this.label,
    required this.hint,
    this.color,
  });
}
