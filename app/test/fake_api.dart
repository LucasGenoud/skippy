import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sticky_notes/api/api_client.dart';
import 'package:sticky_notes/models/note.dart';

/// In-memory [Api] for tests: mirrors the server's semantics closely enough
/// to exercise the store (patch merging, label sets, history), with failure
/// injection for offline/retry paths.
class FakeApi implements Api {
  final Map<String, Note> notes = {};
  final Map<String, Label> labels = {};

  /// Edit history per note id, newest first (tests seed this directly).
  final Map<String, List<NoteVersion>> versions = {};

  /// Checked-item history keyed by note id (per-note suggestions).
  Map<String, List<String>> history = {};
  Map<String, dynamic> settings = {};

  /// Server feature flags returned by [fetchCapabilities]; tests flip these to
  /// exercise the availability logic.
  ({bool semanticSearch, bool audioTranscription}) capabilities = (
    semanticSearch: true,
    audioTranscription: false,
  );

  /// When set, every call throws it (network-down simulation).
  Exception? failWith;

  /// Every API call, in order — lets tests assert on sync behavior.
  final List<String> log = [];

  final StreamController<void> _events = StreamController<void>.broadcast();

  void pushChangeEvent() => _events.add(null);

  Future<T> _run<T>(String op, T Function() body) async {
    log.add(op);
    final fail = failWith;
    if (fail != null) throw fail;
    return body();
  }

  @override
  Future<({String token, AuthUser user})> register(
    String username,
    String password,
  ) => _run(
    'register',
    () => (
      token: 't-$username',
      user: AuthUser(id: 'u-$username', username: username),
    ),
  );

  @override
  Future<({String token, AuthUser user})> login(
    String username,
    String password,
  ) => _run(
    'login',
    () => (
      token: 't-$username',
      user: AuthUser(id: 'u-$username', username: username),
    ),
  );

  @override
  Future<void> logout() => _run('logout', () {});

  @override
  Future<AuthUser> me() =>
      _run('me', () => const AuthUser(id: 'u-me', username: 'me'));

  @override
  Future<List<Note>> fetchNotes() => _run('fetchNotes', () {
    final list = notes.values.toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return list;
  });

  @override
  Future<void> createNote(Note note) => _run('createNote:${note.id}', () {
    if (notes.containsKey(note.id)) {
      throw ApiException(409, '{"error":"note id already exists"}');
    }
    notes[note.id] = note;
  });

  @override
  Future<void> patchNote(String id, Map<String, dynamic> fields) =>
      _run('patchNote:$id:${fields.keys.join(',')}', () {
        final existing = notes[id];
        if (existing == null) throw ApiException(404, '{"error":"not found"}');
        notes[id] = existing.copyWith(
          kind: fields.containsKey('kind')
              ? NoteKind.fromWire(fields['kind'] as String?)
              : null,
          title: fields['title'] as String?,
          content: fields['content'] as String?,
          items: fields.containsKey('items')
              ? [
                  for (final j in fields['items'] as List)
                    ChecklistItem.fromJson(j as Map<String, dynamic>),
                ]
              : null,
          color: fields['color'] as String?,
          pinned: fields['pinned'] as bool?,
          archived: fields['archived'] as bool?,
          trashed: fields['trashed'] as bool?,
          position: (fields['position'] as num?)?.toDouble(),
          reminderAt: fields.containsKey('reminder_at')
              ? (fields['reminder_at'] == null
                    ? null
                    : DateTime.parse(fields['reminder_at'] as String).toLocal())
              : existing.reminderAt,
          labelIds: fields.containsKey('label_ids')
              ? (fields['label_ids'] as List).cast<String>().toSet()
              : null,
          updatedAt: DateTime.now(),
        );
      });

  @override
  Future<void> deleteNote(String id) => _run('deleteNote:$id', () {
    if (notes.remove(id) == null) {
      throw ApiException(404, '{"error":"not found"}');
    }
  });

  @override
  Future<void> reorderNotes(List<String> ids) =>
      _run('reorder:${ids.join('|')}', () {
        for (var i = 0; i < ids.length; i++) {
          final note = notes[ids[i]];
          if (note != null) {
            notes[ids[i]] = note.copyWith(position: (i + 1) * 1024.0);
          }
        }
      });

  @override
  Future<List<NoteVersion>> fetchNoteVersions(String noteId) => _run(
    'fetchVersions:$noteId',
    () => List<NoteVersion>.from(versions[noteId] ?? const []),
  );

  @override
  Future<Note> restoreNoteVersion(String noteId, String versionId) =>
      _run('restoreVersion:$noteId:$versionId', () {
        final note = notes[noteId];
        if (note == null) throw ApiException(404, '{"error":"not found"}');
        final list = versions[noteId] ?? const [];
        final v = list.firstWhere(
          (e) => e.id == versionId,
          orElse: () => throw ApiException(404, '{"error":"not found"}'),
        );
        // Checkpoint the current state, then roll content back — mirrors the
        // server so the store's optimistic replace is exercised faithfully.
        versions[noteId] = [
          NoteVersion(
            id: 'chk-${list.length}',
            noteId: noteId,
            kind: note.kind,
            title: note.title,
            content: note.content,
            items: note.items,
            createdAt: DateTime.now(),
          ),
          ...list,
        ];
        final restored = note.copyWith(
          kind: v.kind,
          title: v.title,
          content: v.content,
          items: v.items,
          updatedAt: DateTime.now(),
        );
        notes[noteId] = restored;
        return restored;
      });

  @override
  Future<Map<String, List<String>>> fetchChecklistHistory() => _run(
    'fetchHistory',
    () => {
      for (final entry in history.entries)
        entry.key: List<String>.from(entry.value),
    },
  );

  @override
  Future<List<Label>> fetchLabels() => _run('fetchLabels', () {
    final list = labels.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  });

  @override
  Future<void> createLabel(String id, String name) =>
      _run('createLabel:$name', () {
        labels[id] = Label(id: id, name: name);
      });

  @override
  Future<void> renameLabel(String id, String name) =>
      _run('renameLabel:$id', () {
        labels[id] = Label(id: id, name: name);
      });

  @override
  Future<void> deleteLabel(String id) => _run('deleteLabel:$id', () {
    labels.remove(id);
  });

  @override
  Future<Note> addCollaborator(String noteId, String username) =>
      _run('addCollaborator:$noteId:$username', () {
        final note = notes[noteId];
        if (note == null) throw ApiException(404, '{"error":"not found"}');
        if (username == 'nobody') {
          throw ApiException(400, '{"error":"no user named \'nobody\'"}');
        }
        final updated = note.copyWith(
          collaborators: [
            ...note.collaborators,
            UserRef(id: 'u-$username', username: username),
          ],
        );
        notes[noteId] = updated;
        return updated;
      });

  @override
  Future<void> removeCollaborator(String noteId, String userId) => _run(
    'removeCollaborator:$noteId:$userId',
    () {
      final note = notes[noteId];
      if (note == null) throw ApiException(404, '{"error":"not found"}');
      notes[noteId] = note.copyWith(
        collaborators: note.collaborators.where((c) => c.id != userId).toList(),
      );
    },
  );

  @override
  Future<Attachment> uploadAttachment(
    String noteId,
    Uint8List bytes,
    String mime,
    String filename,
  ) => _run('upload:$noteId:$filename', () {
    final note = notes[noteId];
    if (note == null) throw ApiException(404, '{"error":"not found"}');
    final attachment = Attachment(
      id: 'att-${bytes.length}',
      mime: mime,
      filename: filename,
      size: bytes.length,
    );
    notes[noteId] = note.copyWith(
      attachments: [...note.attachments, attachment],
    );
    return attachment;
  });

  @override
  Future<void> deleteAttachment(String attachmentId) =>
      _run('deleteAttachment:$attachmentId', () {});

  @override
  String fileUrl(String attachmentId) => 'http://fake.test/files/$attachmentId';

  /// Poor-man's semantic search: keyword containment ranked by match count.
  @override
  Future<List<String>> semanticSearch(
    String query, {
    int limit = 20,
  }) => _run('semanticSearch:$query', () {
    final terms = query.toLowerCase().split(RegExp(r'\s+'));
    final scored = <(String, int)>[];
    for (final note in notes.values) {
      final text =
          '${note.title} ${note.content} ${note.items.map((i) => i.text).join(' ')}'
              .toLowerCase();
      final score = terms.where(text.contains).length;
      if (score > 0) scored.add((note.id, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(limit)) s.$1];
  });

  @override
  Future<({bool semanticSearch, bool audioTranscription})>
  fetchCapabilities() => _run('fetchCapabilities', () => capabilities);

  @override
  Future<void> transcribeNote(String noteId) =>
      _run('transcribe:$noteId', () {
        if (!notes.containsKey(noteId)) {
          throw ApiException(404, '{"error":"not found"}');
        }
      });

  @override
  Future<Map<String, dynamic>> fetchSettings() =>
      _run('fetchSettings', () => Map<String, dynamic>.from(settings));

  @override
  Future<void> putSettings(Map<String, dynamic> value) =>
      _run('putSettings', () => settings = Map<String, dynamic>.from(value));

  @override
  Stream<void> changeEvents() => _events.stream;
}
