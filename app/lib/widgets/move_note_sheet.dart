import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/motion.dart';
import 'form_dialog.dart';
import '../util/label_style.dart';
import 'note_actions.dart';

/// Where a note can be filed from its editor.
enum NoteMoveTarget { stage, collection, workspace }

extension NoteMoveTargetLabel on NoteMoveTarget {
  /// The tab name, and the end of "Move to …" when it is the only one.
  String get label => switch (this) {
    NoteMoveTarget.stage => 'Column',
    NoteMoveTarget.collection => 'Collection',
    NoteMoveTarget.workspace => 'Workspace',
  };
}

/// One picker for every place a note can go: column, collection, workspace.
///
/// The editor's menu used to list one row per kind of destination. Here the
/// kinds are tabs over the destinations themselves, so a move is still two
/// taps from the menu, and a note with a single kind of destination shows that
/// list with no tabs at all.
class MoveNoteSheet extends StatefulWidget {
  final String noteId;
  final List<NoteMoveTarget> targets;
  final NoteMoveTarget initial;

  const MoveNoteSheet({
    super.key,
    required this.noteId,
    required this.targets,
    required this.initial,
  });

  static Future<void> show(
    BuildContext context,
    String noteId, {
    required List<NoteMoveTarget> targets,
    NoteMoveTarget? initial,
  }) {
    if (targets.isEmpty) {
      return Future.value();
    }
    final store = context.read<NotesStore>();
    return showAdaptiveSelectionSurface<void>(
      context,
      isScrollControlled: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: MoveNoteSheet(
          noteId: noteId,
          targets: targets,
          initial: initial ?? targets.first,
        ),
      ),
    );
  }

  @override
  State<MoveNoteSheet> createState() => _MoveNoteSheetState();
}

class _MoveNoteSheetState extends State<MoveNoteSheet> {
  late NoteMoveTarget _target = widget.initial;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final note = store.noteById(widget.noteId);
    if (note == null) {
      return const SizedBox.shrink();
    }

    final tabbed = widget.targets.length > 1;
    final duration = Motion.reduced(context) ? Duration.zero : Motion.base;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModalHeader(
              title: tabbed
                  ? 'Move to'
                  : 'Move to ${_target.label.toLowerCase()}',
            ),
            if (tabbed)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, kSpaceSm, 20, 0),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final target in widget.targets)
                      ChoiceChip(
                        key: ValueKey('move-tab-${target.name}'),
                        label: Text(target.label),
                        selected: target == _target,
                        onSelected: (_) => setState(() => _target = target),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: kSpaceSm),
            // The list grows or shrinks to the tab's length rather than
            // jumping, and the destinations cross-fade.
            Flexible(
              child: AnimatedSize(
                duration: duration,
                curve: Motion.emphasized,
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: duration,
                  switchInCurve: Motion.standard,
                  switchOutCurve: Motion.standard,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topCenter,
                    children: [...previous, ?current],
                  ),
                  child: SingleChildScrollView(
                    key: ValueKey(_target),
                    padding: const EdgeInsets.only(bottom: kSpaceSm),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _destinations(context, store, note),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _destinations(
    BuildContext context,
    NotesStore store,
    Note note,
  ) => switch (_target) {
    NoteMoveTarget.stage => [
      _Destination(
        leading: _dot(context, null),
        label: 'Unassigned',
        selected: note.stageId == null,
        onTap: () => _done(() => store.setNoteStage(note.id, null)),
      ),
      for (final stage in store.stagesForNote(note))
        _Destination(
          leading: _dot(context, PaletteEntry.hexToColor(stage.color)),
          label: stage.name,
          selected: note.stageId == stage.id,
          onTap: () => _done(() => store.setNoteStage(note.id, stage.id)),
        ),
    ],
    NoteMoveTarget.collection => [
      for (final collection
          in store.workspaceById(note.workspaceId)?.collections ?? const [])
        _Destination(
          leading: Icon(
            collection.icon == null
                ? Icons.folder_outlined
                : labelIconFor(collection.icon),
            color: PaletteEntry.hexToColor(collection.color),
          ),
          label: collection.name,
          selected: note.collectionId == collection.id,
          onTap: () =>
              _done(() => store.moveToCollection(note.id, collection.id)),
        ),
    ],
    NoteMoveTarget.workspace => [
      for (final workspace in store.workspaces)
        _Destination(
          leading: const Icon(Icons.workspaces_outlined),
          label: workspace.name,
          subtitle: workspace.isShared
              ? '${workspace.members.length + 1} people'
              : null,
          selected: note.workspaceId == workspace.id,
          onTap: () =>
              _done(() => moveNoteToWorkspace(store, note.id, workspace.id)),
        ),
    ],
  };

  /// Closes the sheet, then moves: the move can take the note out of the
  /// view behind the sheet, and that should not happen under it.
  void _done(VoidCallback move) {
    Navigator.of(context).pop();
    move();
  }

  Widget _dot(BuildContext context, Color? color) => Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      shape: BoxShape.circle,
    ),
  );
}

/// One place to move to. Picking where the note already is closes the sheet
/// and changes nothing.
class _Destination extends StatelessWidget {
  final Widget leading;
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _Destination({
    required this.leading,
    required this.label,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      title: Text(label, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: selected ? const Icon(Icons.check) : null,
      selected: selected,
      onTap: selected ? () => Navigator.of(context).pop() : onTap,
    );
  }
}
