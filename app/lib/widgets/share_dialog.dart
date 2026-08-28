import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/notes_store.dart';
import '../theme.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'form_dialog.dart';
import 'public_link_dialog.dart';

/// Collaborator management for a note. Owners add/remove people by email;
/// collaborators can see the roster and leave.
class ShareDialog extends StatefulWidget {
  final String noteId;
  const ShareDialog({super.key, required this.noteId});

  /// Returns true if the current user left the note (caller should close the
  /// editor too).
  static Future<bool> show(BuildContext context, String noteId) async {
    final left = await showFormDialog<bool>(
      context,
      builder: (_) => ShareDialog(noteId: noteId),
    );
    return left ?? false;
  }

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final email = _controller.text.trim();
    if (email.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<NotesStore>().addCollaborator(widget.noteId, email);
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
    final note = store.noteById(widget.noteId);
    if (note == null) {
      return FormDialog(
        title: const Text('Collaborators'),
        content: const Text('Note is gone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final me = store.currentUserId;
    final isOwner = note.isOwnedBy(me);
    final scheme = Theme.of(context).colorScheme;

    return FormDialog(
      title: const Text('Collaborators'),
      width: kDialogWidth,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 16,
              child: Text(
                (note.owner?.name ?? '?').substring(0, 1).toUpperCase(),
              ),
            ),
            title: Text(note.owner?.name ?? 'You'),
            subtitle: const Text('Owner'),
            dense: true,
          ),
          for (final collaborator in note.collaborators)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: scheme.secondaryContainer,
                child: Text(collaborator.name.substring(0, 1).toUpperCase()),
              ),
              title: Text(
                collaborator.id == me
                    ? '${collaborator.name} (you)'
                    : collaborator.name,
              ),
              trailing: (isOwner || collaborator.id == me)
                  ? IconButton(
                      icon: Icon(
                        collaborator.id == me ? Icons.logout : Icons.close,
                      ),
                      tooltip: collaborator.id == me ? 'Leave note' : 'Remove',
                      onPressed: () {
                        final leaving = collaborator.id == me;
                        store.removeCollaborator(
                          widget.noteId,
                          collaborator.id,
                        );
                        if (leaving) {
                          Navigator.of(context).pop(true);
                        }
                      },
                    )
                  : null,
            ),
          if (isOwner) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Add people by email',
                      isDense: true,
                      prefixIcon: Icon(Icons.person_add_alt, size: 20),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: Motion.fast,
                  switchInCurve: Motion.standard,
                  switchOutCurve: Motion.standard,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child),
                  ),
                  child: _busy
                      ? const Padding(
                          key: ValueKey('busy'),
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          key: const ValueKey('send'),
                          icon: const Icon(Icons.send),
                          tooltip: 'Share',
                          onPressed: _add,
                        ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: kSpaceSm),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 24),
            // Sharing with an account and sharing with the world are different
            // enough to keep apart: one grants editing, the other grants
            // reading to anyone holding a URL.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: const Text('Public link'),
              subtitle: const Text('Read-only, for people without an account'),
              onTap: () => PublicLinkDialog.show(
                context,
                target: PublicLinkTarget.note(widget.noteId, note.title),
                api: store.api,
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: kSpaceLg),
              child: Text(
                'Everyone here can edit this note.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Shares a set of owned notes with one person. A single-note dialog exposes
/// its full collaborator roster; this focused form intentionally only adds a
/// person to every eligible note in the current selection.
class BulkShareDialog extends StatefulWidget {
  final List<String> noteIds;
  const BulkShareDialog({super.key, required this.noteIds});

  static Future<void> show(BuildContext context, Iterable<String> noteIds) {
    final ids = noteIds.toList(growable: false);
    if (ids.isEmpty) return Future.value();
    return showFormDialog<void>(
      context,
      builder: (_) => BulkShareDialog(noteIds: ids),
    );
  }

  @override
  State<BulkShareDialog> createState() => _BulkShareDialogState();
}

class _BulkShareDialogState extends State<BulkShareDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _share(List<String> noteIds) async {
    final email = _controller.text.trim();
    if (email.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var shared = 0;
    try {
      final store = context.read<NotesStore>();
      for (final id in noteIds) {
        await store.addCollaborator(id, email);
        shared++;
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnack(
        '$shared ${shared == 1 ? 'note' : 'notes'} shared',
        icon: Icons.person_add_alt_outlined,
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.serverMessage);
    } catch (_) {
      if (mounted) setState(() => _error = "Can't reach the server right now");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final ownedIds = [
      for (final id in widget.noteIds)
        if (store.noteById(id)?.isOwnedBy(store.currentUserId) == true) id,
    ];
    final skipped = widget.noteIds.length - ownedIds.length;
    final scheme = Theme.of(context).colorScheme;
    final plural = ownedIds.length == 1 ? 'note' : 'notes';

    return FormDialog(
      title: Text('Share ${ownedIds.length} $plural'),
      width: kDialogWidth,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Everyone you add can edit these notes.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (skipped > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$skipped shared ${skipped == 1 ? 'note is' : 'notes are'} excluded because only owners can share.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: ownedIds.isNotEmpty && !_busy,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: 'Add person by email',
              prefixIcon: const Icon(Icons.person_add_alt_outlined),
              errorText: _error,
            ),
            onSubmitted: (_) => _share(ownedIds),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: ownedIds.isEmpty || _busy ? null : () => _share(ownedIds),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_add_alt_outlined),
          label: const Text('Share'),
        ),
      ],
    );
  }
}
