import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/notes_store.dart';
import '../util/snack.dart';

/// Collaborator management for a note. Owners add/remove people by email;
/// collaborators can see the roster and leave.
class ShareDialog extends StatefulWidget {
  final String noteId;
  const ShareDialog({super.key, required this.noteId});

  /// Returns true if the current user left the note (caller should close the
  /// editor too).
  static Future<bool> show(BuildContext context, String noteId) async {
    final left = await showDialog<bool>(
      context: context,
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
      return const AlertDialog(content: Text('Note is gone.'));
    }
    final me = store.currentUserId;
    final isOwner = note.isOwnedBy(me);
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Collaborators'),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
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
                        tooltip: collaborator.id == me
                            ? 'Leave note'
                            : 'Remove',
                        onPressed: () {
                          final leaving = collaborator.id == me;
                          store.removeCollaborator(
                            widget.noteId,
                            collaborator.id,
                          );
                          if (leaving) {
                            Navigator.of(context).pop(true);
                            showAppSnack('You left the note');
                          }
                        },
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
                        decoration: const InputDecoration(
                          hintText: 'Add people by email',
                          isDense: true,
                          prefixIcon: Icon(Icons.person_add_alt, size: 20),
                        ),
                        onSubmitted: (_) => _add(),
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
                            tooltip: 'Share',
                            onPressed: _add,
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
            ] else
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Everyone here can edit this note.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
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
