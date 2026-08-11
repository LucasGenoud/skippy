import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/workspace.dart';
import '../state/notes_store.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import '../util/workspace_stats.dart';
import '../widgets/empty_state.dart';
import '../widgets/workspace_menu.dart';
import 'workspace_stats_screen.dart';

/// Settings for one workspace: its name, which views it offers, who is in it,
/// what it holds, and how to delete or leave it.
///
/// A page rather than a dialog at every width, unlike the short forms that go
/// through [showFormDialog]: these settings belong to the workspace the way the
/// account's belong to the account, and they are read as often as they are
/// changed.
class WorkspaceSettingsScreen extends StatelessWidget {
  final String workspaceId;

  const WorkspaceSettingsScreen({super.key, required this.workspaceId});

  static Route<void> route(String workspaceId) => MaterialPageRoute(
    builder: (_) => WorkspaceSettingsScreen(workspaceId: workspaceId),
  );

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final workspace = store.workspaceById(workspaceId);

    if (workspace == null) {
      // Deleted or left on another device while this page was open.
      return Scaffold(
        appBar: AppBar(title: const Text('Workspace')),
        body: const EmptyState(
          icon: Icons.workspaces_outlined,
          message: 'This workspace is gone.',
        ),
      );
    }

    final isOwner = workspace.isOwnedBy(store.currentUserId);

    return Scaffold(
      appBar: AppBar(title: Text(workspace.name)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const SectionHeader('General'),
              ListTile(
                leading: const Icon(Icons.workspaces_outlined),
                title: Text(workspace.name),
                subtitle: Text(
                  isOwner
                      ? 'Owned by you'
                      : 'Owned by ${workspace.owner?.name ?? 'someone else'}',
                ),
                trailing: isOwner
                    ? IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Rename workspace',
                        onPressed: () =>
                            WorkspaceNameDialog.rename(context, workspace),
                      )
                    : null,
              ),
              const Divider(height: 32),
              const SectionHeader('Views'),
              _ViewsSection(workspace: workspace, isOwner: isOwner),
              const Divider(height: 32),
              const SectionHeader('Statistics'),
              _StatisticsTile(workspaceId: workspace.id),
              const Divider(height: 32),
              const SectionHeader('People'),
              _PeopleSection(workspace: workspace, isOwner: isOwner),
              const Divider(height: 32),
              const SectionHeader('Danger zone'),
              _DangerZone(workspace: workspace, isOwner: isOwner),
            ],
          ),
        ),
      ),
    );
  }
}

/// The same small caps header the account settings use, so the two settings
/// pages read as one family.
class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _ViewsSection extends StatelessWidget {
  final Workspace workspace;
  final bool isOwner;

  const _ViewsSection({required this.workspace, required this.isOwner});

  @override
  Widget build(BuildContext context) {
    final store = context.read<NotesStore>();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.sticky_note_2_outlined),
          title: const Text('Notes'),
          subtitle: const Text('Grid and list view'),
          value: workspace.notesEnabled,
          // The last enabled view can't be switched off, so a workspace always
          // has somewhere to show its notes.
          onChanged:
              isOwner && (!workspace.notesEnabled || workspace.boardEnabled)
              ? (value) => store.updateWorkspaceViews(
                  id: workspace.id,
                  notesEnabled: value,
                  boardEnabled: workspace.boardEnabled,
                )
              : null,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.view_kanban_outlined),
          title: const Text('Board'),
          subtitle: const Text('Kanban view with columns'),
          value: workspace.boardEnabled,
          onChanged:
              isOwner && (!workspace.boardEnabled || workspace.notesEnabled)
              ? (value) => store.updateWorkspaceViews(
                  id: workspace.id,
                  notesEnabled: workspace.notesEnabled,
                  boardEnabled: value,
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            isOwner
                ? 'At least one view must stay enabled.'
                : 'Only the owner can change workspace views.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Opens the statistics page, summarizing what it will show so the row is
/// worth reading even when nobody taps it.
class _StatisticsTile extends StatelessWidget {
  final String workspaceId;

  const _StatisticsTile({required this.workspaceId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    // Counted the same way the page itself counts, so the summary can never
    // disagree with the headline the tap leads to.
    final stats = computeWorkspaceStats(
      notes: store.notesInWorkspace(workspaceId),
      labels: store.labelsInWorkspace(workspaceId),
      stages: store.stagesInWorkspace(workspaceId),
      now: DateTime.now(),
    );
    return ListTile(
      leading: const Icon(Icons.insights_outlined),
      title: const Text('Statistics'),
      subtitle: Text(
        '${_count(stats.activeNotes, 'note')} · '
        '${_count(stats.labelCount, 'label')}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(
        context,
      ).push(WorkspaceStatsScreen.route(workspaceId)),
    );
  }

  static String _count(int n, String noun) =>
      '$n ${n == 1 ? noun : '${noun}s'}';
}

class _PeopleSection extends StatefulWidget {
  final Workspace workspace;
  final bool isOwner;

  const _PeopleSection({required this.workspace, required this.isOwner});

  @override
  State<_PeopleSection> createState() => _PeopleSectionState();
}

class _PeopleSectionState extends State<_PeopleSection> {
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
        widget.workspace.id,
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

  void _remove(String? userId) {
    if (userId == null) return;
    final store = context.read<NotesStore>();
    final leaving = userId == store.currentUserId;
    store.removeWorkspaceMember(widget.workspace.id, userId);
    // Leaving takes the workspace away, and with it this page.
    if (leaving) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final workspace = widget.workspace;
    final me = store.currentUserId;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: CircleAvatar(
            radius: 16,
            child: Text(workspaceInitial(workspace.owner?.name ?? '?')),
          ),
          title: Text(
            widget.isOwner ? 'You' : (workspace.owner?.name ?? 'Owner'),
          ),
          subtitle: const Text('Owner'),
        ),
        for (final member in workspace.members)
          ListTile(
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: scheme.secondaryContainer,
              child: Text(workspaceInitial(member.name)),
            ),
            title: Text(member.id == me ? '${member.name} (you)' : member.name),
            subtitle: const Text('Member'),
            trailing: (widget.isOwner || member.id == me)
                ? IconButton(
                    icon: Icon(member.id == me ? Icons.logout : Icons.close),
                    tooltip: member.id == me ? 'Leave workspace' : 'Remove',
                    onPressed: () => _remove(member.id),
                  )
                : null,
          ),
        if (widget.isOwner) ...[
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
            widget.isOwner
                ? 'Everyone here can see and edit this workspace\'s notes and labels.'
                : 'Everyone here can see and edit this workspace\'s notes and labels. Only the owner can invite people.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _DangerZone extends StatelessWidget {
  final Workspace workspace;
  final bool isOwner;

  const _DangerZone({required this.workspace, required this.isOwner});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final scheme = Theme.of(context).colorScheme;

    if (store.canDeleteWorkspace(workspace.id)) {
      return ListTile(
        leading: Icon(Icons.delete_outline, color: scheme.error),
        title: Text(
          'Delete workspace',
          style: TextStyle(color: scheme.error),
        ),
        subtitle: const Text(
          'Permanently removes its notes, labels, and board columns',
        ),
        onTap: () => _confirmDelete(context, store),
      );
    }
    if (!isOwner) {
      return ListTile(
        leading: const Icon(Icons.logout),
        title: const Text('Leave workspace'),
        subtitle: const Text('Its notes stay with everyone else'),
        onTap: () {
          final me = store.currentUserId;
          if (me == null) return;
          store.removeWorkspaceMember(workspace.id, me);
          Navigator.of(context).pop();
        },
      );
    }
    // The workspace created with the account: it has nowhere to hand its notes
    // over to, so it can be neither deleted nor left.
    return ListTile(
      leading: Icon(Icons.lock_outline, color: scheme.onSurfaceVariant),
      title: const Text('Your default workspace'),
      subtitle: const Text('It can\'t be deleted, so notes always have a home'),
      enabled: false,
    );
  }

  Future<void> _confirmDelete(BuildContext context, NotesStore store) async {
    final noteCount = store
        .notesInWorkspace(workspace.id)
        .where((note) => !note.trashed)
        .length;
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _DeleteWorkspaceDialog(workspace: workspace, noteCount: noteCount),
    );
    if (confirmed != true || !navigator.mounted) return;
    await Motion.waitForOverlayDismissal(navigator.context);
    if (!navigator.mounted) return;
    store.deleteWorkspace(workspace.id);
    navigator.pop();
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
