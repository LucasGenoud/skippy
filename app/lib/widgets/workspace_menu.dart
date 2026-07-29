import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/workspace.dart';
import '../state/notes_store.dart';
import '../theme.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'form_dialog.dart';

/// The workspace switcher that heads the drawer and the sidebar: the open
/// workspace's name, and a menu to switch, create, or manage.
class WorkspaceMenu extends StatelessWidget {
  /// Collapsed rails show the initial only, with the name in a tooltip.
  final bool compact;

  /// Runs before a selected action starts. The phone drawer uses this to
  /// finish closing before another route is presented.
  final Future<void> Function()? onBeforeAction;

  const WorkspaceMenu({super.key, this.compact = false, this.onBeforeAction});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final active = store.activeWorkspace;
    final scheme = Theme.of(context).colorScheme;
    // Before the first load resolves a workspace there is nothing to switch
    // between; the header stays put rather than flashing a placeholder name.
    final name = active?.name ?? 'Workspace';

    return Padding(
      // Inset to the same 12px as the sidebar items below, so the card lines
      // up with their selection pills.
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        // An ink surface of the switcher's own. Without it both the card
        // (an `Ink` decoration) and the tap ripple would paint onto the
        // Scaffold's material, which the rail's opaque background covers —
        // leaving no card at all. Transparent: the rail still shows through.
        type: MaterialType.transparency,
        child: Tooltip(
          message: compact ? name : '',
          child: PopupMenuButton<String>(
            popUpAnimationStyle: Motion.menuFor(context),
            tooltip: 'Switch workspace',
            position: PopupMenuPosition.under,
            onSelected: (value) => _onSelected(context, store, value),
            itemBuilder: (context) => [
              for (final workspace in store.workspaces)
                // A plain item with our own check, not CheckedPopupMenuItem:
                // that one *fades* a checkmark in over 150ms on the row you
                // tap and never clears the outgoing row's, so both read as
                // selected for the whole dismiss. The tick here just moves.
                PopupMenuItem(
                  value: 'open:${workspace.id}',
                  child: Row(
                    children: [
                      // Fixed slot, so names line up whether or not the row
                      // is the active one.
                      SizedBox(
                        width: 32,
                        // Watched, not read: PopupMenuButton snapshots these
                        // items when the menu opens, so without a listener of
                        // its own the row could never restate itself. The
                        // providers live above MaterialApp (see main.dart)
                        // precisely so pushed routes like this one can. The
                        // route is still mounted while it fades out, so the
                        // tick lands on the new workspace the moment the
                        // store flips.
                        child: Consumer<NotesStore>(
                          builder: (context, store, _) =>
                              workspace.id == store.activeWorkspaceId
                              ? const Icon(Icons.check, size: 18)
                              : const SizedBox.shrink(),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          workspace.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (workspace.isShared ||
                          !workspace.isOwnedBy(store.currentUserId))
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.group_outlined,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'create',
                child: ListTile(
                  leading: Icon(Icons.add),
                  title: Text('New workspace'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'manage',
                enabled: active != null,
                child: const ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Manage workspace'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
            borderRadius: kBorderRadius,
            // The switcher reads as a card of its own — the drawer and the
            // rail it heads are plain surfaces, so a bordered, slightly
            // raised tile marks it as the one thing here that opens a menu
            // rather than navigating. `Ink`, not a Container: it paints into
            // the material below the splash, so the tap ripple stays visible
            // on top of the fill.
            child: Ink(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: kBorderRadius,
                border: Border.all(color: scheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _initial(name),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(
                        Icons.expand_more,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _initial(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }

  Future<void> _onSelected(
    BuildContext context,
    NotesStore store,
    String value,
  ) async {
    if (value.startsWith('open:')) {
      // Switching is ordinary state, not another overlay. Update immediately
      // so the checkmark moves with the menu's own dismiss animation.
      onBeforeAction?.call();
      store.setActiveWorkspace(value.substring(5));
      return;
    }
    // The switcher can live inside the phone drawer. Keep a context owned by
    // the navigator before that drawer subtree is removed, then wait for its
    // close animation so a new route cannot overlap it and immediately pop.
    final navigator = Navigator.of(context);
    final menuDismissal = Motion.waitForMenuDismissal(context);
    final beforeAction = onBeforeAction?.call();
    await Future.wait([menuDismissal, ?beforeAction]);
    if (!navigator.mounted) return;
    if (value == 'create') {
      await _createWorkspace(navigator);
      return;
    }
    final active = store.activeWorkspace;
    if (active != null) {
      await _manageWorkspace(navigator, active.id);
    }
  }

  static Future<void> _createWorkspace(NavigatorState navigator) =>
      WorkspaceNameDialog.create(navigator.context);

  static Future<void> _manageWorkspace(
    NavigatorState navigator,
    String workspaceId,
  ) => ManageWorkspaceDialog.show(navigator.context, workspaceId);
}

/// Names a new workspace, or renames an existing one.
class WorkspaceNameDialog extends StatefulWidget {
  /// Null creates a workspace; otherwise the one being renamed.
  final Workspace? workspace;

  const WorkspaceNameDialog({super.key, this.workspace});

  static Future<void> create(BuildContext context) => showFormDialog<void>(
    context,
    builder: (_) => const WorkspaceNameDialog(),
  );

  static Future<void> rename(BuildContext context, Workspace workspace) =>
      showFormDialog<void>(
        context,
        builder: (_) => WorkspaceNameDialog(workspace: workspace),
      );

  @override
  State<WorkspaceNameDialog> createState() => _WorkspaceNameDialogState();
}

class _WorkspaceNameDialogState extends State<WorkspaceNameDialog> {
  late final _controller = TextEditingController(
    text: widget.workspace?.name ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    final store = context.read<NotesStore>();
    final existing = widget.workspace;
    Navigator.of(context).pop();
    if (existing == null) {
      store.createWorkspace(name);
      showAppSnack('Switched to "$name"', icon: Icons.workspaces_outlined);
    } else {
      store.renameWorkspace(existing.id, name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.workspace == null;
    return FormDialog(
      title: Text(creating ? 'New workspace' : 'Rename workspace'),
      width: 360,
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(
          hintText: 'Workspace name',
          prefixIcon: Icon(Icons.workspaces_outlined),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(creating ? 'Create' : 'Rename'),
        ),
      ],
    );
  }
}

/// Workspace settings: rename it, manage who is in it, and delete or leave.
class ManageWorkspaceDialog extends StatefulWidget {
  final String workspaceId;

  const ManageWorkspaceDialog({super.key, required this.workspaceId});

  static Future<void> show(BuildContext context, String workspaceId) =>
      showFormDialog<void>(
        context,
        builder: (_) => ManageWorkspaceDialog(workspaceId: workspaceId),
      );

  @override
  State<ManageWorkspaceDialog> createState() => _ManageWorkspaceDialogState();
}

class _ManageWorkspaceDialogState extends State<ManageWorkspaceDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final email = _controller.text.trim();
    if (email.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<NotesStore>().addWorkspaceMember(
        widget.workspaceId,
        email,
      );
      _controller.clear();
    } on ApiException catch (e) {
      _error = e.serverMessage;
    } catch (_) {
      _error = "Can't reach the server right now";
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final workspace = store.workspaceById(widget.workspaceId);
    if (workspace == null) {
      return FormDialog(
        title: const Text('Workspace'),
        content: const Text('Workspace is gone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final me = store.currentUserId;
    final isOwner = workspace.isOwnedBy(me);
    final scheme = Theme.of(context).colorScheme;
    final noteCount = store.notesInActiveWorkspace
        .where((note) => note.workspaceId == workspace.id && !note.trashed)
        .length;

    return FormDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(workspace.name, overflow: TextOverflow.ellipsis),
          ),
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Rename workspace',
              onPressed: () => WorkspaceNameDialog.rename(context, workspace),
            ),
        ],
      ),
      width: 400,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 16,
              child: Text(WorkspaceMenu._initial(workspace.owner?.name ?? '?')),
            ),
            title: Text(isOwner ? 'You' : (workspace.owner?.name ?? 'Owner')),
            subtitle: const Text('Owner'),
          ),
          for (final member in workspace.members)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: scheme.secondaryContainer,
                child: Text(WorkspaceMenu._initial(member.name)),
              ),
              title: Text(
                member.id == me ? '${member.name} (you)' : member.name,
              ),
              subtitle: const Text('Member'),
              trailing: (isOwner || member.id == me)
                  ? IconButton(
                      icon: Icon(member.id == me ? Icons.logout : Icons.close),
                      tooltip: member.id == me ? 'Leave workspace' : 'Remove',
                      onPressed: () => _remove(store, workspace, member.id),
                    )
                  : null,
            ),
          if (isOwner) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        hintText: 'Invite people by email',
                        isDense: true,
                        prefixIcon: Icon(Icons.person_add_alt, size: 20),
                      ),
                      onSubmitted: (_) => _invite(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.send),
                          tooltip: 'Invite',
                          onPressed: _invite,
                        ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              isOwner
                  ? 'Everyone here can see and edit this workspace\'s notes and labels.'
                  : 'Everyone here can see and edit this workspace\'s notes and labels. Only the owner can invite people.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      actions: [
        if (store.canDeleteWorkspace(workspace.id))
          TextButton.icon(
            onPressed: () => _confirmDelete(store, workspace, noteCount),
            icon: Icon(Icons.delete_outline, color: scheme.error),
            label: Text('Delete', style: TextStyle(color: scheme.error)),
          )
        else if (!isOwner)
          TextButton.icon(
            onPressed: () => _remove(store, workspace, me),
            icon: const Icon(Icons.logout),
            label: const Text('Leave'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  void _remove(NotesStore store, Workspace workspace, String? userId) {
    if (userId == null) return;
    final leaving = userId == store.currentUserId;
    store.removeWorkspaceMember(workspace.id, userId);
    if (leaving) {
      Navigator.of(context).pop();
      showAppSnack('You left "${workspace.name}"', icon: Icons.logout);
    }
  }

  Future<void> _confirmDelete(
    NotesStore store,
    Workspace workspace,
    int noteCount,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _DeleteWorkspaceDialog(workspace: workspace, noteCount: noteCount),
    );
    if (confirmed != true || !mounted) return;
    await Motion.waitForOverlayDismissal(context);
    if (!mounted) return;
    store.deleteWorkspace(workspace.id);
    if (mounted) Navigator.of(context).pop();
    showAppSnack(
      'Deleted "${workspace.name}"',
      icon: Icons.delete_outline,
      kind: SnackKind.danger,
    );
  }
}

/// Deleting a workspace permanently removes its notes, attachments, shared
/// taxonomy, and roster, so the name confirmation makes the destructive scope
/// explicit.
class _DeleteWorkspaceDialog extends StatefulWidget {
  final Workspace workspace;
  final int noteCount;

  const _DeleteWorkspaceDialog({
    required this.workspace,
    required this.noteCount,
  });

  @override
  State<_DeleteWorkspaceDialog> createState() => _DeleteWorkspaceDialogState();
}

class _DeleteWorkspaceDialogState extends State<_DeleteWorkspaceDialog> {
  final _controller = TextEditingController();
  String _typed = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _matches => _typed == widget.workspace.name;

  void _submit() {
    if (_matches) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final noteCount = widget.noteCount;
    final deletionMessage = switch (noteCount) {
      0 => 'Its labels and board columns are removed. This can\'t be undone.',
      1 =>
        '1 note and all its attachments will be permanently deleted. '
            'This can\'t be undone.',
      _ =>
        '$noteCount notes and all their attachments will be permanently '
            'deleted. This can\'t be undone.',
    };
    return AlertDialog(
      title: Text('Delete "${widget.workspace.name}"?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(deletionMessage),
          const SizedBox(height: 16),
          Text.rich(
            TextSpan(
              text: 'Type ',
              children: [
                TextSpan(
                  text: widget.workspace.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: ' to confirm.'),
              ],
            ),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _typed = v),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: _matches ? _submit : null,
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

/// Picks a workspace to file a note in. Only the note's owner can move it, so
/// callers gate on that first.
class MoveToWorkspaceSheet {
  static Future<void> show(BuildContext context, String noteId) async {
    final store = context.read<NotesStore>();
    final note = store.noteById(noteId);
    if (note == null) return;
    final target = await showAdaptiveSelectionSurface<String>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Move to workspace',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final workspace in store.workspaces)
              ListTile(
                onTap: () => Navigator.of(context).pop(workspace.id),
                leading: Icon(
                  workspace.id == note.workspaceId
                      ? Icons.check
                      : Icons.workspaces_outlined,
                ),
                title: Text(workspace.name),
                subtitle: workspace.isShared
                    ? Text('${workspace.members.length + 1} people')
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (target == null || target == note.workspaceId) return;
    final droppedLabels = note.labelIds
        .where((id) => store.labelById(id)?.workspaceId != target)
        .length;
    store.moveNoteToWorkspace(noteId, target);
    showAppSnack(
      droppedLabels == 0
          ? 'Moved to "${store.workspaceById(target)?.name}"'
          : 'Moved to "${store.workspaceById(target)?.name}" — '
                '$droppedLabels ${droppedLabels == 1 ? 'label' : 'labels'} removed',
      icon: Icons.drive_file_move_outlined,
    );
  }
}
