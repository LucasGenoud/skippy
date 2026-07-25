import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/workspace.dart';
import '../state/notes_store.dart';
import '../theme.dart';
import '../util/motion.dart';
import '../util/snack.dart';

/// The workspace switcher that heads the drawer and the sidebar: the open
/// workspace's name, and a menu to switch, create, or manage.
class WorkspaceMenu extends StatelessWidget {
  /// Collapsed rails show the initial only, with the name in a tooltip.
  final bool compact;

  /// Runs before the menu opens — the drawer closes itself first, so its
  /// route doesn't sit above the dialogs the menu opens.
  final VoidCallback? onBeforeAction;

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
                // that one fades a checkmark *in* on the row you tap (150ms)
                // and leaves the outgoing row's check alone, so for the whole
                // dismiss animation two workspaces looked selected. Drawn
                // statically, the tick stays on the current workspace until
                // the menu is gone.
                PopupMenuItem(
                  value: 'open:${workspace.id}',
                  child: Row(
                    children: [
                      // Fixed slot, so names line up whether or not the row
                      // is the active one.
                      SizedBox(
                        width: 32,
                        child: workspace.id == store.activeWorkspaceId
                            ? const Icon(Icons.check, size: 18)
                            : null,
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

  void _onSelected(BuildContext context, NotesStore store, String value) {
    onBeforeAction?.call();
    if (value.startsWith('open:')) {
      store.setActiveWorkspace(value.substring(5));
      return;
    }
    if (value == 'create') {
      WorkspaceNameDialog.create(context);
      return;
    }
    final active = store.activeWorkspace;
    if (active != null) ManageWorkspaceDialog.show(context, active.id);
  }
}

/// Names a new workspace, or renames an existing one.
class WorkspaceNameDialog extends StatefulWidget {
  /// Null creates a workspace; otherwise the one being renamed.
  final Workspace? workspace;

  const WorkspaceNameDialog({super.key, this.workspace});

  static Future<void> create(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const WorkspaceNameDialog());

  static Future<void> rename(BuildContext context, Workspace workspace) =>
      showDialog<void>(
        context: context,
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
    return AlertDialog(
      title: Text(creating ? 'New workspace' : 'Rename workspace'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'Workspace name',
            prefixIcon: Icon(Icons.workspaces_outlined),
          ),
          onSubmitted: (_) => _submit(),
        ),
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
      showDialog<void>(
        context: context,
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
      return const AlertDialog(content: Text('Workspace is gone.'));
    }
    final me = store.currentUserId;
    final isOwner = workspace.isOwnedBy(me);
    final scheme = Theme.of(context).colorScheme;
    final noteCount = store.notesInActiveWorkspace
        .where((note) => note.workspaceId == workspace.id && !note.trashed)
        .length;

    return AlertDialog(
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
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                child: Text(
                  WorkspaceMenu._initial(workspace.owner?.name ?? '?'),
                ),
              ),
              title: Text(
                isOwner ? 'You' : (workspace.owner?.name ?? 'Owner'),
              ),
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
                        icon: Icon(
                          member.id == me ? Icons.logout : Icons.close,
                        ),
                        tooltip: member.id == me
                            ? 'Leave workspace'
                            : 'Remove',
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
      showAppSnack(
        'You left "${workspace.name}"',
        icon: Icons.logout,
      );
    }
  }

  Future<void> _confirmDelete(
    NotesStore store,
    Workspace workspace,
    int noteCount,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${workspace.name}"?'),
        content: Text(
          noteCount == 0
              ? 'Its labels are removed. Nothing else changes.'
              : 'Its $noteCount ${noteCount == 1 ? 'note goes' : 'notes go'} back to your default workspace, '
                    'and any note a member owns goes back to theirs. The workspace\'s labels are removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    store.deleteWorkspace(workspace.id);
    if (mounted) Navigator.of(context).pop();
    showAppSnack(
      'Deleted "${workspace.name}"',
      icon: Icons.delete_outline,
      kind: SnackKind.danger,
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
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Move to workspace'),
        children: [
          for (final workspace in store.workspaces)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(workspace.id),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
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
            ),
        ],
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

