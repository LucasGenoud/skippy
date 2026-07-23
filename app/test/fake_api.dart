import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/chat.dart';
import 'package:skippy/models/link_preview.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/search_stats.dart';

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
  Completer<void>? fetchHistoryGate;
  Map<String, dynamic> settings = {};

  /// Server feature flags returned by [fetchCapabilities]; tests flip these to
  /// exercise the availability logic.
  ({bool semanticSearch, bool audioTranscription}) capabilities = (
    semanticSearch: true,
    audioTranscription: false,
  );

  /// Server-managed settings returned by [fetchManagedSettings]; empty means
  /// nothing is env-pinned. Tests populate it to exercise field locking.
  Map<String, ManagedSetting> managedSettings = {};

  /// Canned link-preview responses keyed by URL, returned by [unfurl]. Tests
  /// populate it; unknown URLs unfurl to null (no card).
  Map<String, LinkPreview> previews = {};

  /// When set, every call throws it (network-down simulation).
  Exception? failWith;

  /// Every API call, in order — lets tests assert on sync behavior.
  final List<String> log = [];

  final StreamController<void> _events = StreamController<void>.broadcast();

  AuthUser account = const AuthUser(
    id: 'u-me',
    name: 'Me Example',
    email: 'me@example.test',
  );

  void pushChangeEvent() => _events.add(null);

  Future<T> _run<T>(String op, T Function() body) async {
    log.add(op);
    final fail = failWith;
    if (fail != null) throw fail;
    return body();
  }

  @override
  Future<void> checkConnection() => _run('checkConnection', () {});

  @override
  Future<({String token, AuthUser user})> register(
    String name,
    String email,
    String password,
  ) => _run(
    'register',
    () => (
      token: 't-$email',
      user: AuthUser(id: 'u-$email', name: name, email: email),
    ),
  );

  @override
  Future<({String token, AuthUser user})> login(
    String email,
    String password,
  ) => _run(
    'login',
    () => (
      token: 't-$email',
      user: AuthUser(id: 'u-$email', name: email, email: email),
    ),
  );

  @override
  Future<void> logout() => _run('logout', () {});

  @override
  Future<AuthUser> me() => _run('me', () => account);

  @override
  Future<AuthUser> updateAccount({
    String? name,
    String? email,
    String? currentPassword,
    String? newPassword,
  }) => _run('updateAccount', () {
    account = AuthUser(
      id: account.id,
      name: name ?? account.name,
      email: email ?? account.email,
    );
    return account;
  });

  @override
  Future<List<Note>> fetchNotes() => _run('fetchNotes', () {
    final list = notes.values.toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return list;
  });

  @override
  Future<void> createNote(Note note, {bool preserveTimestamps = false}) =>
      _run('createNote:${note.id}', () {
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
  Future<Note> rewriteNote(String id, NoteRewriteMode mode) =>
      _run('rewriteNote:$id:${mode.wire}', () {
        final note = notes[id];
        if (note == null) throw ApiException(404, '{"error":"not found"}');
        final updated = switch (mode) {
          NoteRewriteMode.concise => note.copyWith(
            content: 'Concise: ${note.content}',
            updatedAt: DateTime.now(),
          ),
          NoteRewriteMode.grammar => note.copyWith(
            content: 'Corrected: ${note.content}',
            updatedAt: DateTime.now(),
          ),
        };
        notes[id] = updated;
        _events.add(null);
        return updated;
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
  Future<Map<String, List<String>>> fetchChecklistHistory() async {
    final result = await _run(
      'fetchHistory',
      () => {
        for (final entry in history.entries)
          entry.key: List<String>.from(entry.value),
      },
    );
    final gate = fetchHistoryGate;
    if (gate != null) await gate.future;
    return result;
  }

  @override
  Future<List<Label>> fetchLabels() => _run('fetchLabels', () {
    final list = labels.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  });

  @override
  Future<void> createLabel(
    String id,
    String name, {
    String? color,
    String? icon,
  }) => _run('createLabel:$name', () {
    labels[id] = Label(
      id: id,
      name: name,
      color: (color ?? '').isEmpty ? null : color,
      icon: (icon ?? '').isEmpty ? null : icon,
    );
  });

  @override
  Future<void> updateLabel(
    String id,
    String name, {
    String? color,
    String? icon,
  }) => _run('updateLabel:$id', () {
    labels[id] = Label(
      id: id,
      name: name,
      color: (color ?? '').isEmpty ? null : color,
      icon: (icon ?? '').isEmpty ? null : icon,
    );
  });

  @override
  Future<void> deleteLabel(String id) => _run('deleteLabel:$id', () {
    labels.remove(id);
  });

  @override
  Future<Note> addCollaborator(String noteId, String email) =>
      _run('addCollaborator:$noteId:$email', () {
        final note = notes[noteId];
        if (note == null) throw ApiException(404, '{"error":"not found"}');
        if (email == 'nobody@example.test') {
          throw ApiException(400, '{"error":"no account for email"}');
        }
        final name = email.split('@').first;
        final updated = note.copyWith(
          collaborators: [
            ...note.collaborators,
            UserRef(id: 'u-$email', name: name),
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

  @override
  String attachmentUrl(Attachment attachment) => attachment.url != null
      ? 'http://fake.test${attachment.url}'
      : fileUrl(attachment.id);

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
  Future<LinkPreview?> unfurl(String url) =>
      _run('unfurl:$url', () => previews[url]);

  @override
  Future<({bool semanticSearch, bool audioTranscription})>
  fetchCapabilities() => _run('fetchCapabilities', () => capabilities);

  /// Number of notes queued by the most recent [reindexEmbeddings] call.
  int reindexedCount = 0;

  @override
  Future<SearchStats> fetchSearchStats() => _run('fetchSearchStats', () {
    if (!capabilities.semanticSearch) return SearchStats.disabled;
    return SearchStats(
      enabled: true,
      model: 'fake-embedder',
      dimensions: 8,
      totalNotes: notes.length,
      indexedNotes: notes.length,
    );
  });

  @override
  Future<int> reindexEmbeddings() => _run('reindexEmbeddings', () {
    reindexedCount = notes.length;
    return notes.length;
  });

  /// Reindex progress returned by [fetchReindexStatus]; tests can set this to
  /// simulate an in-flight job. Defaults to "idle/finished".
  ({bool running, int done, int total}) reindexStatus = (
    running: false,
    done: 0,
    total: 0,
  );

  @override
  Future<({bool running, int done, int total})> fetchReindexStatus() =>
      _run('fetchReindexStatus', () => reindexStatus);

  @override
  Future<Map<String, ManagedSetting>> fetchManagedSettings() =>
      _run('fetchManagedSettings', () => managedSettings);

  @override
  Future<void> transcribeNote(String noteId) => _run('transcribe:$noteId', () {
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

  /// Result of [testLlm]; tests flip this to exercise the failure path.
  bool llmTestOk = true;

  @override
  Future<({bool ok, String? error})> testLlm({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) => _run(
    'testLlm',
    () => (ok: llmTestOk, error: llmTestOk ? null : 'connection refused'),
  );

  /// Result of [testNotify]; tests flip this to exercise the failure path.
  bool notifyTestOk = true;

  /// Config sent with the most recent [testNotify] call.
  Map<String, String>? lastNotifyTestConfig;

  @override
  Future<({bool ok, String? error})> testNotify(Map<String, String> config) =>
      _run('testNotify', () {
        lastNotifyTestConfig = Map<String, String>.from(config);
        return (ok: notifyTestOk, error: notifyTestOk ? null : 'ntfy: boom');
      });

  /// Frames [chat] replays for a turn; tests override to script a chat.
  List<ChatEvent> chatScript = const [
    ChatSourcesEvent([]),
    ChatDeltaEvent('Hello '),
    ChatDeltaEvent('there.'),
    ChatDoneEvent(),
  ];

  /// History sent with the most recent [chat] call.
  List<ChatMessage>? lastChatHistory;

  @override
  Stream<ChatEvent> chat(String message, List<ChatMessage> history) {
    log.add('chat:$message');
    lastChatHistory = history;
    final fail = failWith;
    if (fail != null) return Stream.error(fail);
    return Stream.fromIterable(chatScript);
  }
}
