import 'package:flutter/material.dart';

import '../../models/note.dart';
import '../form_dialog.dart';

/// Everything you do *to* a note, as opposed to what you put *into* it.
///
/// The editor has two action surfaces and they are split by intent rather than
/// by depth: the bottom bar composes (colour, labels, reminder, image, file)
/// and this app-bar menu manages (share, file, convert, delete). An earlier
/// design nested the rarer half of one combined menu behind "More note
/// options", which asked the reader to guess whether a thing like "Move to
/// column" counted as advanced — it doesn't, it is just infrequent, and hiding
/// it turned a two-tap job into a hunt.
///
/// So this list is flat: one scrollable column, every row reachable in two
/// taps. The two families that would otherwise contribute five near-identical
/// rows — the AI rewrites and the kind conversions — collapse into a chip row
/// each, which is what keeps the flat list short enough to scan.
///
/// Copy to clipboard and Archive are not here: they are frequent enough to sit
/// in the app bar as their own buttons, immediately left of this one.
class NoteActionsButton extends StatelessWidget {
  final bool isOwner;
  final NoteKind kind;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;
  final VoidCallback? onMoveToWorkspace;
  final VoidCallback? onMoveToStage;
  final VoidCallback? onHistory;
  final VoidCallback? onAddToHomeScreen;
  final void Function(NoteKind target)? onConvert;
  final ValueChanged<NoteRewriteMode>? onRewrite;

  /// Swaps the trigger for a spinner while an AI rewrite is in flight, and
  /// disables re-running one from the sheet.
  final bool rewriting;

  const NoteActionsButton({
    super.key,
    required this.isOwner,
    required this.kind,
    this.onShare,
    this.onDelete,
    this.onDuplicate,
    this.onMoveToWorkspace,
    this.onMoveToStage,
    this.onHistory,
    this.onAddToHomeScreen,
    this.onConvert,
    this.onRewrite,
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

  bool get _offersRewrite => onRewrite != null && kind != NoteKind.audio;

  List<_NoteAction> _rows(ColorScheme scheme) => [
    if (onShare != null)
      const _NoteAction(
        value: 'share',
        icon: Icons.person_add_alt_outlined,
        label: 'Collaborators',
      ),
    // Above "Move to workspace", in the same order the note card's menu lists
    // the two.
    if (onMoveToStage != null)
      const _NoteAction(
        value: 'stage',
        icon: Icons.view_kanban_outlined,
        label: 'Move to column',
      ),
    if (onMoveToWorkspace != null)
      const _NoteAction(
        value: 'move',
        icon: Icons.drive_file_move_outlined,
        label: 'Move to workspace',
      ),
    if (onHistory != null)
      const _NoteAction(
        value: 'history',
        icon: Icons.history,
        label: 'Version history',
      ),
    if (onDuplicate != null)
      const _NoteAction(
        value: 'duplicate',
        icon: Icons.copy_all_outlined,
        label: 'Duplicate',
      ),
    // Only where the device has a home screen to put it on.
    if (onAddToHomeScreen != null)
      const _NoteAction(
        value: 'homescreen',
        icon: Icons.widgets_outlined,
        label: 'Add to Home Screen',
      ),
    if (isOwner && onDelete != null)
      _NoteAction(
        value: 'delete',
        icon: Icons.delete_outline,
        label: 'Delete',
        color: scheme.error,
      ),
  ];

  void _dispatch(String value) {
    if (value == 'share') onShare?.call();
    if (value == 'delete') onDelete?.call();
    if (value == 'duplicate') onDuplicate?.call();
    if (value == 'move') onMoveToWorkspace?.call();
    if (value == 'stage') onMoveToStage?.call();
    if (value == 'history') onHistory?.call();
    if (value == 'homescreen') onAddToHomeScreen?.call();
    if (value == 'concise') onRewrite?.call(NoteRewriteMode.concise);
    if (value == 'grammar') onRewrite?.call(NoteRewriteMode.grammar);
    for (final target in NoteKind.values) {
      if (value == 'convert:${target.name}') onConvert?.call(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows(Theme.of(context).colorScheme);
    final empty = rows.isEmpty && _convertTargets.isEmpty && !_offersRewrite;
    return IconButton(
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
                  rows: rows,
                  convertTargets: _convertTargets,
                  offersRewrite: _offersRewrite,
                  rewriting: rewriting,
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
  final List<_NoteAction> rows;
  final List<NoteKind> convertTargets;
  final bool offersRewrite;
  final bool rewriting;

  const _NoteActionsSheet({
    required this.rows,
    required this.convertTargets,
    required this.offersRewrite,
    required this.rewriting,
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
                  'Note actions',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (offersRewrite)
                _ChipRow(
                  title: 'Rewrite with AI',
                  chips: [
                    ActionChip(
                      avatar: const Icon(Icons.auto_fix_high_outlined, size: 18),
                      label: const Text('Make concise'),
                      onPressed: rewriting
                          ? null
                          : () => Navigator.pop(context, 'concise'),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.spellcheck_outlined, size: 18),
                      label: const Text('Fix grammar'),
                      onPressed: rewriting
                          ? null
                          : () => Navigator.pop(context, 'grammar'),
                    ),
                  ],
                ),
              if (convertTargets.isNotEmpty)
                _ChipRow(
                  title: 'Turn into',
                  chips: [
                    for (final target in convertTargets)
                      NoteActionsButton._kindChip(context, target),
                  ],
                ),
              if (rows.isNotEmpty &&
                  (offersRewrite || convertTargets.isNotEmpty))
                const Divider(height: 24),
              for (final row in rows)
                ListTile(
                  key: ValueKey('note-action-${row.value}'),
                  leading: Icon(row.icon, color: row.color),
                  title: Text(
                    row.label,
                    style: row.color == null
                        ? null
                        : TextStyle(color: row.color),
                  ),
                  onTap: () => Navigator.pop(context, row.value),
                ),
            ],
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
          const SizedBox(height: 8),
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

  /// Tints icon and label, used to flag the destructive Delete.
  final Color? color;

  const _NoteAction({
    required this.value,
    required this.icon,
    required this.label,
    this.color,
  });
}
