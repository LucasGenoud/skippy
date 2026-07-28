import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/chat.dart';
import 'package:skippy/models/link_preview.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/search_stats.dart';
import 'package:skippy/models/workspace.dart';

/// In-memory [Api] for tests: mirrors the server's semantics closely enough
/// to exercise the store (patch merging, label sets, history), with failure
/// injection for offline/retry paths.
class FakeApi implements Api {
  final Map<String, Note> notes = {};
  final Map<String, Label> labels = {};
  final Map<String, Stage> stages = {};

  /// Workspaces keyed by id. Seeded with the default one every account has, so
  /// tests that predate workspaces still get a coherent world.
  final Map<String, Workspace> workspaces = {
    'w-default': const Workspace(
      id: 'w-default',
      name: 'My notes',
      owner: UserRef(id: 'u-me', name: 'Me Example'),
      isDefault: true,
    ),
  };

  /// Edit history per note id, newest first (tests seed this directly).
  final Map<String, List<NoteVersion>> versions = {};

  /// Checked-item history keyed by note id (per-note suggestions).
  Map<String, List<String>> history = {};
  Completer<void>? fetchWorkspacesGate;
  Completer<void>? fetchCapabilitiesGate;
  Completer<void>? fetchLabelsGate;
  Completer<void>? fetchHistoryGate;
  Completer<void>? patchGate;
  Completer<void>? rewriteGate;
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

  /// Id of the default workspace, where the server files anything created
  /// without one named.
  String get defaultWorkspaceId =>
      workspaces.values.firstWhere((w) => w.isDefault).id;

  /// A note's effective workspace. Fixtures often build notes directly without
  /// one; the server would have filed those in the default workspace.
  String _workspaceOf(Note note) =>
      note.workspaceId.isEmpty ? defaultWorkspaceId : note.workspaceId;

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
  Future<List<Workspace>> fetchWorkspaces() async {
    final gate = fetchWorkspacesGate;
    if (gate != null) {
      fetchWorkspacesGate = null;
      await gate.future;
    }
    return _run('fetchWorkspaces', () {
      final list = workspaces.values.toList()
        ..sort((a, b) {
          if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
          return a.name.compareTo(b.name);
        });
      return list;
    });
  }

  @override
  Future<Workspace> createWorkspace(String id, String name) =>
      _run('createWorkspace:$name', () {
        final workspace = Workspace(
          id: id,
          name: name,
          owner: UserRef(id: account.id, name: account.name),
        );
        workspaces[id] = workspace;
        return workspace;
      });

  @override
  Future<Workspace> renameWorkspace(String id, String name) =>
      _run('renameWorkspace:$id', () {
        final existing = workspaces[id];
        if (existing == null) throw ApiException(404, '{"error":"not found"}');
        return workspaces[id] = existing.copyWith(name: name);
      });

  @override
  Future<void> deleteWorkspace(String id) => _run('deleteWorkspace:$id', () {
    if (workspaces.remove(id) == null) {
      throw ApiException(404, '{"error":"not found"}');
    }
    // Notes outlive their workspace. This fake models what the current account
    // can still see after the server moves each note to its owner's default:
    // our notes and direct shares remain; workspace-only notes disappear.
    for (final entry in notes.entries.toList()) {
      final note = entry.value;
      if (note.workspaceId != id) continue;
      final retained =
          note.isOwnedBy(account.id) ||
          note.collaborators.any((user) => user.id == account.id);
      if (retained) {
        notes[entry.key] = note.copyWith(
          workspaceId: note.isOwnedBy(account.id)
              ? defaultWorkspaceId
              : note.workspaceId,
          labelIds: const {},
          stageId: null,
        );
      } else {
        notes.remove(entry.key);
      }
    }
    labels.removeWhere((_, label) => label.workspaceId == id);
    stages.removeWhere((_, stage) => stage.workspaceId == id);
  });

  @override
  Future<Workspace> addWorkspaceMember(String workspaceId, String email) =>
      _run('addWorkspaceMember:$workspaceId:$email', () {
        final existing = workspaces[workspaceId];
        if (existing == null) throw ApiException(404, '{"error":"not found"}');
        if (!email.contains('@')) {
          throw ApiException(400, '{"error":"no account for \'$email\'"}');
        }
        return workspaces[workspaceId] = existing.copyWith(
          members: [
            ...existing.members,
            UserRef(id: 'u-$email', name: email.split('@').first),
          ],
        );
      });

  @override
  Future<void> removeWorkspaceMember(String workspaceId, String userId) =>
      _run('removeWorkspaceMember:$workspaceId:$userId', () {
        final existing = workspaces[workspaceId];
        if (existing == null) throw ApiException(404, '{"error":"not found"}');
        workspaces[workspaceId] = existing.copyWith(
          members: existing.members.where((m) => m.id != userId).toList(),
        );
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
        notes[note.id] = note.workspaceId.isEmpty
            ? note.copyWith(workspaceId: defaultWorkspaceId)
            : note;
      });

  @override
  Future<void> patchNote(String id, Map<String, dynamic> fields) async {
    final gate = patchGate;
    if (gate != null) {
      patchGate = null;
      await gate.future;
    }
    return _run('patchNote:$id:${fields.keys.join(',')}', () {
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
        workspaceId: fields['workspace_id'] as String?,
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
        // Present-but-null means "back to unassigned", so the key's presence
        // is what decides — matching the server's nested Option. An absent
        // key re-passes the current value, the way reminder_at does above.
        stageId: fields.containsKey('stage_id')
            ? _resolveStage(fields['stage_id'] as String?)
            : existing.stageId,
        stagePosition: (fields['stage_position'] as num?)?.toDouble(),
        updatedAt: DateTime.now(),
      );
    });
  }

  /// A stage the server would refuse — unknown, or from another workspace —
  /// is dropped rather than honoured, so client tests meet the same rule the
  /// API tests pin down.
  String? _resolveStage(String? id) => stages.containsKey(id) ? id : null;

  @override
  Future<Note> rewriteNote(String id, NoteRewriteMode mode) async {
    final gate = rewriteGate;
    if (gate != null) await gate.future;
    return _run('rewriteNote:$id:${mode.wire}', () {
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
  }

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
  Future<List<Label>> fetchLabels() async {
    final result = await _run('fetchLabels', () {
      final list = labels.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    });
    final gate = fetchLabelsGate;
    if (gate != null) {
      fetchLabelsGate = null;
      await gate.future;
    }
    return result;
  }

  @override
  Future<void> createLabel(
    String id,
    String name, {
    required String workspaceId,
    String? color,
    String? icon,
  }) => _run('createLabel:$name', () {
    labels[id] = Label(
      id: id,
      workspaceId: workspaceId,
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
      workspaceId: labels[id]?.workspaceId ?? '',
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
  Future<List<Stage>> fetchStages() => _run('fetchStages', () {
    final list = stages.values.toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return list;
  });

  @override
  Future<void> createStage(
    String id,
    String name, {
    required String workspaceId,
    String? color,
    double? position,
  }) => _run('createStage:$name', () {
    stages[id] = Stage(
      id: id,
      workspaceId: workspaceId,
      name: name,
      color: (color ?? '').isEmpty ? null : color,
      position: position ?? _nextStagePosition(workspaceId),
    );
  });

  double _nextStagePosition(String workspaceId) {
    var max = 0.0;
    for (final stage in stages.values) {
      if (stage.workspaceId == workspaceId && stage.position > max) {
        max = stage.position;
      }
    }
    return max + 1024.0;
  }

  @override
  Future<void> updateStage(
    String id,
    String name, {
    String? color,
    double? position,
  }) => _run('updateStage:$id', () {
    final existing = stages[id];
    stages[id] = Stage(
      id: id,
      workspaceId: existing?.workspaceId ?? '',
      name: name,
      color: (color ?? '').isEmpty ? null : color,
      position: position ?? existing?.position ?? 0,
    );
  });

  @override
  Future<void> deleteStage(String id) => _run('deleteStage:$id', () {
    stages.remove(id);
    // Notes outlive their column, exactly as the server's delete does.
    for (final entry in notes.entries.toList()) {
      if (entry.value.stageId == id) {
        notes[entry.key] = entry.value.copyWith(stageId: null);
      }
    }
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
    String? workspaceId,
  }) => _run('semanticSearch:$query', () {
    final terms = query.toLowerCase().split(RegExp(r'\s+'));
    final scored = <(String, int)>[];
    for (final note in notes.values) {
      if (workspaceId != null && _workspaceOf(note) != workspaceId) continue;
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
  fetchCapabilities() async {
    final gate = fetchCapabilitiesGate;
    if (gate != null) {
      fetchCapabilitiesGate = null;
      await gate.future;
    }
    return _run('fetchCapabilities', () => capabilities);
  }

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

  /// Workspace sent with the most recent [chat] call.
  String? lastChatWorkspaceId;

  @override
  Stream<ChatEvent> chat(
    String message,
    List<ChatMessage> history, {
    String? workspaceId,
  }) {
    log.add('chat:$message');
    lastChatHistory = history;
    lastChatWorkspaceId = workspaceId;
    final fail = failWith;
    if (fail != null) return Stream.error(fail);
    return Stream.fromIterable(chatScript);
  }
}
