import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/notes_store.dart';
import '../util/mime.dart';
import '../util/note_export.dart';
import '../util/snack.dart';
import 'share_dialog.dart';

// What the note card, the editor and the home screen all do to a note,
// written once so they cannot drift apart: each changes the store and says
// what happened, with an undo where there is one.

/// Archives [note], or brings it back out of the archive, offering an undo.
void toggleArchive(NotesStore store, Note note) {
  final wasArchived = note.archived;
  store.setArchived(note.id, !wasArchived);
  showAppSnack(
    wasArchived ? 'Note unarchived' : 'Note archived',
    icon: wasArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
    actionLabel: 'Undo',
    onAction: () => store.setArchived(note.id, wasArchived),
  );
}

/// Moves the note to Trash, offering an undo.
void trashNote(NotesStore store, String id) {
  store.moveToTrash(id);
  showAppSnack(
    'Note moved to Trash',
    icon: Icons.delete_outline,
    kind: SnackKind.danger,
    actionLabel: 'Undo',
    onAction: () => store.restoreFromTrash(id),
  );
}

/// Puts [note] on the clipboard as plain text.
Future<void> copyNoteText(Note note) => Clipboard.setData(
  // trimRight: the export's block form ends with a blank line to separate
  // notes; a paste shouldn't carry that.
  ClipboardData(text: noteToPlainText(note).trimRight()),
);

/// Opens the collaborators dialog for [note], unless there is nothing in it
/// to share yet. Answers whether the user left the note from that dialog.
Future<bool> shareNote(BuildContext context, Note? note) async {
  if (note == null || note.isEmpty) {
    showAppSnack('Add some content before sharing');
    return false;
  }
  return ShareDialog.show(context, note.id);
}

/// Has the workspace's AI rewrite the note, and says how that went. Answers
/// whether the note was rewritten.
Future<bool> rewriteWithAi(
  NotesStore store,
  String id,
  NoteRewriteTask task,
) async {
  try {
    await store.rewriteNote(id, task);
  } catch (_) {
    showAppSnack(
      "Couldn't update the note with AI",
      icon: Icons.error_outline,
      kind: SnackKind.danger,
    );
    return false;
  }
  showAppSnack('${task.name} complete', icon: Icons.auto_fix_high_outlined);
  return true;
}

/// [files] without the ones over the upload limit, saying so when any had to
/// be left out.
List<DroppedFile> withinUploadLimit(List<DroppedFile> files) {
  final accepted = [
    for (final file in files)
      if (file.bytes.length <= maxUploadBytes) file,
  ];
  if (accepted.length != files.length) {
    showAppSnack(
      'Files are limited to ${maxUploadBytes ~/ _bytesPerMegabyte} MB',
      icon: Icons.error_outline,
      kind: SnackKind.warning,
    );
  }
  return accepted;
}

const int _bytesPerMegabyte = 1024 * 1024;
