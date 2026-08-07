import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat.dart';
import '../models/link_preview.dart';
import '../models/note.dart';
import '../models/search_stats.dart';
import '../models/share_link.dart';
import '../models/workspace.dart';
import '../util/runtime_config.dart';

part 'api_transport.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);

  /// Human-readable server error, if the body was our JSON error envelope.
  String get serverMessage {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return message;
  }

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Everything the stores need from the backend. Tests swap in a fake.
abstract class Api {
  /// Lightweight reachability probe used by the sync indicator. Implementors
  /// must fail promptly when the server cannot be reached.
  Future<void> checkConnection();

  // auth
  Future<({String token, AuthUser user})> register(
    String name,
    String email,
    String password,
  );
  Future<({String token, AuthUser user})> login(String email, String password);
  Future<void> logout();
  Future<AuthUser> me();
  Future<void> deleteAccount(String currentPassword);
  Future<AuthUser> updateAccount({
    String? name,
    String? email,
    String? currentPassword,
    String? newPassword,
  });

  // workspaces
  /// Every workspace the user owns or was invited to, default first.
  Future<List<Workspace>> fetchWorkspaces();
  Future<Workspace> createWorkspace(String id, String name);
  Future<Workspace> renameWorkspace(String id, String name);
  Future<Workspace> updateWorkspaceViews(
    String id, {
    required bool notesEnabled,
    required bool boardEnabled,
  });
  Future<void> deleteWorkspace(String id);

  /// Invite someone by email; returns the workspace with its new roster.
  Future<Workspace> addWorkspaceMember(String workspaceId, String email);

  /// Remove a member, or leave the workspace by passing your own id.
  Future<void> removeWorkspaceMember(String workspaceId, String userId);

  // notes
  Future<List<Note>> fetchNotes();
  Future<void> createNote(Note note, {bool preserveTimestamps = false});
  Future<void> patchNote(String id, Map<String, dynamic> fields);

  /// Ask the user's enabled AI provider to rewrite a note, returning the
  /// server-updated note so the local store can replace its current copy.
  Future<Note> rewriteNote(String id, NoteRewriteMode mode);
  Future<void> deleteNote(String id);
  Future<void> reorderNotes(List<String> ids);

  /// A note's edit history, newest first.
  Future<List<NoteVersion>> fetchNoteVersions(String noteId);

  /// Roll a note's content back to a past version; returns the updated note.
  /// The server checkpoints the pre-restore state, so this is reversible.
  Future<Note> restoreNoteVersion(String noteId, String versionId);

  /// Previously checked item texts, grouped per note id, most used first.
  /// Suggestions are scoped per note, one note's history never leaks into
  /// another's rows.
  Future<Map<String, List<String>>> fetchChecklistHistory();

  // public share links
  /// Every public link this account has published, newest first.
  Future<List<ShareLink>> fetchShareLinks();

  /// Publish (or hand back the existing link for) one target. Only the owner
  /// of the note, or of the workspace behind a view, may do this.
  Future<ShareLink> createShareLink({
    required ShareTarget target,
    String? noteId,
    String? workspaceId,
    String? labelId,
    DateTime? expiresAt,
  });

  /// Revoke a link. The page it served stops resolving immediately.
  Future<void> deleteShareLink(String token);

  /// Read a public link's payload. Deliberately unauthenticated: the token is
  /// the credential, and the reader usually has no account at all.
  Future<PublicShare> fetchPublicShare(String token);

  // labels
  Future<List<Label>> fetchLabels();
  Future<void> createLabel(
    String id,
    String name, {
    required String workspaceId,
    String? color,
    String? icon,
    double? position,
  });
  Future<void> updateLabel(
    String id,
    String name, {
    String? color,
    String? icon,
    double? position,
  });
  Future<void> deleteLabel(String id);

  // stages (board columns), deliberately parallel to labels rather than
  // sharing an abstraction with them; the two are independent systems.
  Future<List<Stage>> fetchStages();
  Future<void> createStage(
    String id,
    String name, {
    required String workspaceId,
    String? color,
    double? position,
  });
  Future<void> updateStage(
    String id,
    String name, {
    String? color,
    double? position,
  });
  Future<void> deleteStage(String id);

  // sharing
  Future<Note> addCollaborator(String noteId, String email);
  Future<void> removeCollaborator(String noteId, String userId);

  // attachments
  Future<Attachment> uploadAttachment(
    String noteId,
    Uint8List bytes,
    String mime,
    String filename,
  );
  Future<void> deleteAttachment(String attachmentId);
  String fileUrl(String attachmentId);

  /// Absolute, ready-to-load URL for an attachment. Prefers the server's
  /// signed, time-limited URL (so plain `<img>`/`<audio>` loads stay
  /// authorized); falls back to the bare path for older servers.
  String attachmentUrl(Attachment attachment);

  /// Origin of the server this client talks to, for building links a person
  /// can paste elsewhere (see [publicShareUrl]).
  String get baseUrl;

  // per-user settings (opaque JSON document, synced across devices)
  Future<Map<String, dynamic>> fetchSettings();
  Future<void> putSettings(Map<String, dynamic> settings);

  /// Meaning-based search; returns note ids ranked by similarity. Pass
  /// [workspaceId] to keep results inside the open workspace.
  /// Throws [ApiException] (503) when the server has it disabled.
  Future<List<String>> semanticSearch(
    String query, {
    int limit = 20,
    String? workspaceId,
  });

  /// Which optional, service-backed features this server has enabled. Drives
  /// semantic-search availability and whether audio recordings are transcribed.
  Future<
    ({bool semanticSearch, bool audioTranscription, String? serverVersion})
  >
  fetchCapabilities();

  /// Semantic-search index diagnostics: embedding model, vector width, and how
  /// many of the user's notes are indexed. Powers the Settings stats panel.
  Future<SearchStats> fetchSearchStats();

  /// Re-embed all of the user's notes; returns how many will be embedded. The
  /// work runs on the server; poll [fetchReindexStatus] to track it.
  Future<int> reindexEmbeddings();

  /// Progress of a running re-embed job: `running` is false when idle or done,
  /// `done`/`total` drive the progress bar.
  Future<({bool running, int done, int total})> fetchReindexStatus();

  /// Ask the server to (re)transcribe an audio note's clip. Used to retry a
  /// failed transcription.
  Future<void> transcribeNote(String noteId);

  /// Fetch link-preview metadata (Open Graph / HTML) for [url]. Returns null
  /// when the server rejects the URL (invalid/blocked) or the fetch fails.
  Future<LinkPreview?> unfurl(String url);

  /// Server-push change events; emits whenever this user's notes change.
  Stream<void> changeEvents();

  /// Probe an LLM configuration without saving it; powers the "Test
  /// connection" button in Settings. A failed probe resolves normally with
  /// `ok: false` and the reason.
  Future<({bool ok, String? error})> testLlm({
    required String baseUrl,
    required String apiKey,
    required String model,
  });

  /// Probe a notification configuration by sending a real test message;
  /// powers the "Send test" button in Settings. [config] carries the
  /// connector keys exactly as they'd be saved (ntfy_url,
  /// telegram_bot_token, …), so new channels need no API changes. Resolves
  /// normally with `ok: false` and the reason on delivery failure.
  Future<({bool ok, String? error})> testNotify(Map<String, String> config);

  /// One notes-chat turn: sends [message] with prior [history] and emits the
  /// server's frames (sources, streamed deltas, then done/error). The stream
  /// closes after the terminal event. [workspaceId] scopes retrieval, and any
  /// note the turn writes, to the workspace the user has open.
  Stream<ChatEvent> chat(
    String message,
    List<ChatMessage> history, {
    String? workspaceId,
  });
}

class ApiClient extends _ApiTransport implements Api {
  static const connectionProbeTimeout = Duration(seconds: 3);

  /// Ceiling on any ordinary request. Generous enough for a slow mobile link,
  /// short enough that a dead connection is a fast failure rather than a hang.
  /// Attachment uploads bypass it (see [_uploadClient]).
  static const requestTimeout = Duration(seconds: 15);

  /// Resolution order: --dart-define=API_BASE (compile-time), then the URL the
  /// server injected into the page (STICKY_NOTES_PUBLIC_URL env var), then
  /// same-origin when the app is served by the Rust binary itself, then the
  /// local dev default.
  static String defaultBaseUrl() {
    const fromEnv = String.fromEnvironment('API_BASE');
    if (fromEnv.isNotEmpty) return fromEnv;
    final injected = runtimeApiBase();
    if (injected != null && injected.isNotEmpty) return injected;
    if (kIsWeb && Uri.base.port == 8787) return Uri.base.origin;
    return 'http://localhost:8787';
  }

  /// [httpClient] is a test seam (a stubbed or never-answering client stands in
  /// for the network); production leaves it null.
  ApiClient({String? baseUrl, super.httpClient})
    : super(
        baseUrl: baseUrl ?? defaultBaseUrl(),
        requestTimeout: requestTimeout,
        probeTimeout: connectionProbeTimeout,
      );

  // -- auth ----------------------------------------------------------------

  Future<({String token, AuthUser user})> _authCall(
    String path,
    Map<String, String> body,
  ) async {
    final data =
        _decode(
              await _client.post(
                _uri(path),
                headers: {'content-type': 'application/json'},
                body: jsonEncode(body),
              ),
              authed: false,
            )
            as Map<String, dynamic>;
    return (
      token: data['token'] as String,
      user: AuthUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  @override
  Future<({String token, AuthUser user})> register(
    String name,
    String email,
    String password,
  ) => _authCall('/auth/register', {
    'name': name,
    'email': email,
    'password': password,
  });

  @override
  Future<({String token, AuthUser user})> login(
    String email,
    String password,
  ) => _authCall('/auth/login', {'email': email, 'password': password});

  @override
  Future<void> logout() async {
    _decode(
      await _client.post(_uri('/auth/logout'), headers: _headers()),
      authed: false,
    );
  }

  @override
  Future<AuthUser> me() async {
    final requestToken = token;
    final data = _decode(
      await _client.get(_uri('/auth/me'), headers: _headers()),
      requestToken: requestToken,
    );
    return AuthUser.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteAccount(String currentPassword) async {
    final requestToken = token;
    _decode(
      await _client.delete(
        _uri('/auth/me'),
        headers: _headers(),
        body: jsonEncode({'current_password': currentPassword}),
      ),
      requestToken: requestToken,
    );
  }

  @override
  Future<AuthUser> updateAccount({
    String? name,
    String? email,
    String? currentPassword,
    String? newPassword,
  }) async {
    final body = <String, String>{};
    if (name != null) body['name'] = name;
    if (email != null) body['email'] = email;
    if (currentPassword != null) body['current_password'] = currentPassword;
    if (newPassword != null) body['new_password'] = newPassword;
    final data = _decode(
      await _client.patch(
        _uri('/auth/me'),
        headers: _headers(),
        body: jsonEncode(body),
      ),
    );
    return AuthUser.fromJson(data as Map<String, dynamic>);
  }

  // -- workspaces ------------------------------------------------------------

  @override
  Future<List<Workspace>> fetchWorkspaces() async {
    final data =
        _decode(await _client.get(_uri('/workspaces'), headers: _headers()))
            as List;
    return data
        .map((j) => Workspace.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Workspace> createWorkspace(String id, String name) async {
    final data = _decode(
      await _client.post(
        _uri('/workspaces'),
        headers: _headers(),
        body: jsonEncode({'id': id, 'name': name}),
      ),
    );
    return Workspace.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<Workspace> renameWorkspace(String id, String name) async {
    final data = _decode(
      await _client.patch(
        _uri('/workspaces/$id'),
        headers: _headers(),
        body: jsonEncode({'name': name}),
      ),
    );
    return Workspace.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<Workspace> updateWorkspaceViews(
    String id, {
    required bool notesEnabled,
    required bool boardEnabled,
  }) async {
    final data = _decode(
      await _client.patch(
        _uri('/workspaces/$id'),
        headers: _headers(),
        body: jsonEncode({
          'notes_enabled': notesEnabled,
          'board_enabled': boardEnabled,
        }),
      ),
    );
    return Workspace.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteWorkspace(String id) async {
    _decode(await _client.delete(_uri('/workspaces/$id'), headers: _headers()));
  }

  @override
  Future<Workspace> addWorkspaceMember(String workspaceId, String email) async {
    final data = _decode(
      await _client.post(
        _uri('/workspaces/$workspaceId/members'),
        headers: _headers(),
        body: jsonEncode({'email': email}),
      ),
    );
    return Workspace.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> removeWorkspaceMember(String workspaceId, String userId) async {
    _decode(
      await _client.delete(
        _uri('/workspaces/$workspaceId/members/$userId'),
        headers: _headers(),
      ),
    );
  }

  // -- notes ---------------------------------------------------------------

  @override
  Future<List<Note>> fetchNotes() async {
    final data =
        _decode(await _client.get(_uri('/notes'), headers: _headers())) as List;
    return data.map((j) => Note.fromJson(j as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> createNote(Note note, {bool preserveTimestamps = false}) async {
    _decode(
      await _client.post(
        _uri('/notes'),
        headers: _headers(),
        body: jsonEncode({
          'id': note.id,
          if (note.workspaceId.isNotEmpty) 'workspace_id': note.workspaceId,
          'kind': note.kind.wire,
          'title': note.title,
          'content': note.content,
          'items': Note.itemsToJson(note.items),
          'color': note.color,
          'pinned': note.pinned,
          'position': note.position,
          if (note.reminderAt != null)
            'reminder_at': note.reminderAt!.toUtc().toIso8601String(),
          if (note.reminderRepeat != null)
            'reminder_repeat': note.reminderRepeat!.wire,
          // A note composed inside a label view is already filed when it
          // reaches the server; the draft never had a chance to PATCH them.
          'label_ids': note.labelIds.toList(),
          // Same for one composed inside a board column.
          if (note.stageId != null) 'stage_id': note.stageId,
          'stage_position': note.stagePosition,
          if (preserveTimestamps) ...{
            'archived': note.archived,
            'trashed': note.trashed,
            'created_at': note.createdAt.toUtc().toIso8601String(),
            'updated_at': note.updatedAt.toUtc().toIso8601String(),
          },
        }),
      ),
    );
  }

  @override
  Future<void> patchNote(String id, Map<String, dynamic> fields) async {
    _decode(
      await _client.patch(
        _uri('/notes/$id'),
        headers: _headers(),
        body: jsonEncode(fields),
      ),
    );
  }

  @override
  Future<Note> rewriteNote(String id, NoteRewriteMode mode) async {
    final data = _decode(
      await _client.post(
        _uri('/notes/$id/rewrite'),
        headers: _headers(),
        body: jsonEncode({'mode': mode.wire}),
      ),
    );
    return Note.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteNote(String id) async {
    _decode(await _client.delete(_uri('/notes/$id'), headers: _headers()));
  }

  @override
  Future<void> reorderNotes(List<String> ids) async {
    _decode(
      await _client.post(
        _uri('/notes/reorder'),
        headers: _headers(),
        body: jsonEncode({'ids': ids}),
      ),
    );
  }

  @override
  Future<List<NoteVersion>> fetchNoteVersions(String noteId) async {
    final data =
        _decode(
              await _client.get(
                _uri('/notes/$noteId/versions'),
                headers: _headers(),
              ),
            )
            as List;
    return data
        .map((j) => NoteVersion.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Note> restoreNoteVersion(String noteId, String versionId) async {
    final data = _decode(
      await _client.post(
        _uri('/notes/$noteId/versions/$versionId/restore'),
        headers: _headers(),
      ),
    );
    return Note.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<Map<String, List<String>>> fetchChecklistHistory() async {
    final data =
        _decode(
              await _client.get(
                _uri('/checklist-history'),
                headers: _headers(),
              ),
            )
            as List;
    final byNote = <String, List<String>>{};
    for (final entry in data) {
      final map = entry as Map;
      byNote
          .putIfAbsent(map['note_id'] as String, () => [])
          .add(map['text'] as String);
    }
    return byNote;
  }

  // -- public share links ----------------------------------------------------

  @override
  Future<List<ShareLink>> fetchShareLinks() async {
    final data =
        _decode(await _client.get(_uri('/share-links'), headers: _headers()))
            as List;
    return data
        .map((j) => ShareLink.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ShareLink> createShareLink({
    required ShareTarget target,
    String? noteId,
    String? workspaceId,
    String? labelId,
    DateTime? expiresAt,
  }) async {
    final data = _decode(
      await _client.post(
        _uri('/share-links'),
        headers: _headers(),
        body: jsonEncode({
          'target': target.wire,
          'note_id': ?noteId,
          'workspace_id': ?workspaceId,
          'label_id': ?labelId,
          'expires_at': ?expiresAt?.toUtc().toIso8601String(),
        }),
      ),
    );
    return ShareLink.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteShareLink(String token) async {
    _decode(
      await _client.delete(_uri('/share-links/$token'), headers: _headers()),
    );
  }

  @override
  Future<PublicShare> fetchPublicShare(String token) async {
    // No Authorization header: a reader following the link is usually signed
    // out, and sending a stale session token would only risk a 401 handler
    // firing on a page that has nothing to do with the session.
    final data = _decode(
      await _client.get(_uri('/public/$token')),
      authed: false,
    );
    return PublicShare.fromJson(data as Map<String, dynamic>);
  }

  // -- labels ---------------------------------------------------------------

  @override
  Future<List<Label>> fetchLabels() async {
    final data =
        _decode(await _client.get(_uri('/labels'), headers: _headers()))
            as List;
    return data.map((j) => Label.fromJson(j as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> createLabel(
    String id,
    String name, {
    required String workspaceId,
    String? color,
    String? icon,
    double? position,
  }) async {
    _decode(
      await _client.post(
        _uri('/labels'),
        headers: _headers(),
        // Empty strings clear the field server-side; an omitted position
        // appends the label to the end of the sidebar list.
        body: jsonEncode({
          'id': id,
          if (workspaceId.isNotEmpty) 'workspace_id': workspaceId,
          'name': name,
          'color': color ?? '',
          'icon': icon ?? '',
          'position': ?position,
        }),
      ),
    );
  }

  @override
  Future<void> updateLabel(
    String id,
    String name, {
    String? color,
    String? icon,
    double? position,
  }) async {
    _decode(
      await _client.patch(
        _uri('/labels/$id'),
        headers: _headers(),
        body: jsonEncode({
          'name': name,
          'color': color ?? '',
          'icon': icon ?? '',
          'position': ?position,
        }),
      ),
    );
  }

  @override
  Future<void> deleteLabel(String id) async {
    _decode(await _client.delete(_uri('/labels/$id'), headers: _headers()));
  }

  // -- stages ---------------------------------------------------------------

  @override
  Future<List<Stage>> fetchStages() async {
    final data =
        _decode(await _client.get(_uri('/stages'), headers: _headers()))
            as List;
    return data.map((j) => Stage.fromJson(j as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> createStage(
    String id,
    String name, {
    required String workspaceId,
    String? color,
    double? position,
  }) async {
    _decode(
      await _client.post(
        _uri('/stages'),
        headers: _headers(),
        // Empty string clears the colour server-side; an omitted position
        // appends the column to the right of the board.
        body: jsonEncode({
          'id': id,
          if (workspaceId.isNotEmpty) 'workspace_id': workspaceId,
          'name': name,
          'color': color ?? '',
          'position': ?position,
        }),
      ),
    );
  }

  @override
  Future<void> updateStage(
    String id,
    String name, {
    String? color,
    double? position,
  }) async {
    _decode(
      await _client.patch(
        _uri('/stages/$id'),
        headers: _headers(),
        body: jsonEncode({
          'name': name,
          'color': color ?? '',
          'position': ?position,
        }),
      ),
    );
  }

  @override
  Future<void> deleteStage(String id) async {
    _decode(await _client.delete(_uri('/stages/$id'), headers: _headers()));
  }

  // -- sharing ----------------------------------------------------------------

  @override
  Future<Note> addCollaborator(String noteId, String email) async {
    final data = _decode(
      await _client.post(
        _uri('/notes/$noteId/collaborators'),
        headers: _headers(),
        body: jsonEncode({'email': email}),
      ),
    );
    return Note.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> removeCollaborator(String noteId, String userId) async {
    _decode(
      await _client.delete(
        _uri('/notes/$noteId/collaborators/$userId'),
        headers: _headers(),
      ),
    );
  }

  // -- attachments --------------------------------------------------------------

  @override
  Future<Attachment> uploadAttachment(
    String noteId,
    Uint8List bytes,
    String mime,
    String filename,
  ) async {
    final request =
        http.MultipartRequest('POST', _uri('/notes/$noteId/attachments'))
          ..headers.addAll(_headers(json: false))
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: filename.isEmpty ? 'file' : filename,
              contentType: MediaType.parse(mime),
            ),
          );
    final streamed = await _uploadClient.send(request);
    final res = await http.Response.fromStream(streamed);
    final data = _decode(res);
    return Attachment.fromJson(data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteAttachment(String attachmentId) async {
    _decode(
      await _client.delete(
        _uri('/attachments/$attachmentId'),
        headers: _headers(),
      ),
    );
  }

  @override
  String fileUrl(String attachmentId) => '$baseUrl/api/files/$attachmentId';

  @override
  String attachmentUrl(Attachment attachment) {
    final signed = attachment.url;
    if (signed != null && signed.isNotEmpty) return '$baseUrl$signed';
    return fileUrl(attachment.id);
  }

  // -- settings -----------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> fetchSettings() async {
    final data = _decode(
      await _client.get(_uri('/settings'), headers: _headers()),
    );
    return (data as Map?)?.cast<String, dynamic>() ?? {};
  }

  @override
  Future<void> putSettings(Map<String, dynamic> settings) async {
    _decode(
      await _client.put(
        _uri('/settings'),
        headers: _headers(),
        body: jsonEncode(settings),
      ),
    );
  }

  @override
  Future<List<String>> semanticSearch(
    String query, {
    int limit = 20,
    String? workspaceId,
  }) async {
    final uri = _uri('/search').replace(
      queryParameters: {
        'q': query,
        'limit': '$limit',
        if (workspaceId != null && workspaceId.isNotEmpty)
          'workspace_id': workspaceId,
      },
    );
    final data = _decode(await _client.get(uri, headers: _headers())) as List;
    return [for (final hit in data) (hit as Map)['note_id'] as String];
  }

  @override
  Future<LinkPreview?> unfurl(String url) async {
    final uri = _uri('/unfurl').replace(queryParameters: {'url': url});
    try {
      final data = _decode(await _client.get(uri, headers: _headers()));
      if (data is! Map<String, dynamic>) return null;
      return LinkPreview.fromJson(data);
    } on ApiException {
      // Invalid/blocked URL (400) or auth/transient error, no preview.
      return null;
    }
  }

  // -- capabilities & transcription --------------------------------------------

  @override
  Future<
    ({bool semanticSearch, bool audioTranscription, String? serverVersion})
  >
  fetchCapabilities() async {
    // Unauthenticated endpoint; no bearer needed.
    final data = _decode(
      await _client.get(_uri('/capabilities')),
      authed: false,
    );
    final map = (data as Map?) ?? const {};
    return (
      semanticSearch: map['semantic_search'] == true,
      audioTranscription: map['audio_transcription'] == true,
      // Older servers do not advertise their version; leave it unavailable
      // rather than treating a missing field as a malformed response.
      serverVersion: map['server_version']?.toString(),
    );
  }

  @override
  Future<SearchStats> fetchSearchStats() async {
    final data = _decode(
      await _client.get(_uri('/search/stats'), headers: _headers()),
    );
    return SearchStats.fromJson(
      ((data as Map?) ?? const {}).cast<String, dynamic>(),
    );
  }

  @override
  Future<int> reindexEmbeddings() async {
    final data = _decode(
      await _client.post(_uri('/search/reindex'), headers: _headers()),
    );
    return ((data as Map?)?['total'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<({bool running, int done, int total})> fetchReindexStatus() async {
    final data = _decode(
      await _client.get(_uri('/search/reindex/status'), headers: _headers()),
    );
    final map = (data as Map?) ?? const {};
    return (
      running: map['running'] == true,
      done: (map['done'] as num?)?.toInt() ?? 0,
      total: (map['total'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> transcribeNote(String noteId) async {
    _decode(
      await _client.post(
        _uri('/notes/$noteId/transcribe'),
        headers: _headers(),
      ),
    );
  }

  // -- live sync ---------------------------------------------------------------

  @override
  Stream<void> changeEvents() {
    final controller = StreamController<void>();
    WebSocketChannel? channel;
    Timer? reconnect;
    var closed = false;

    late final void Function() connect;
    void scheduleReconnect() {
      if (!closed) reconnect = Timer(const Duration(seconds: 5), connect);
    }

    connect = () {
      final sessionToken = token;
      if (closed || sessionToken == null) return;
      try {
        channel = WebSocketChannel.connect(_webSocketUri('/ws'));
        channel!.sink.add(jsonEncode({'token': sessionToken}));
        channel!.stream.listen(
          (_) => controller.add(null),
          onDone: scheduleReconnect,
          onError: (Object _) => scheduleReconnect(),
        );
      } catch (_) {
        scheduleReconnect();
      }
    };

    controller.onListen = connect;
    controller.onCancel = () {
      closed = true;
      reconnect?.cancel();
      channel?.sink.close();
    };
    return controller.stream;
  }

  // -- LLM ---------------------------------------------------------------------

  @override
  Future<({bool ok, String? error})> testLlm({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final data = _decode(
      await _client.post(
        _uri('/llm/test'),
        headers: _headers(),
        body: jsonEncode({
          'base_url': baseUrl,
          'api_key': apiKey,
          'model': model,
        }),
      ),
    );
    final map = (data as Map?) ?? const {};
    return (ok: map['ok'] == true, error: map['error'] as String?);
  }

  @override
  Future<({bool ok, String? error})> testNotify(
    Map<String, String> config,
  ) async {
    final data = _decode(
      await _client.post(
        _uri('/notify/test'),
        headers: _headers(),
        body: jsonEncode(config),
      ),
    );
    final map = (data as Map?) ?? const {};
    return (ok: map['ok'] == true, error: map['error'] as String?);
  }

  @override
  Stream<ChatEvent> chat(
    String message,
    List<ChatMessage> history, {
    String? workspaceId,
  }) {
    // One WebSocket per turn: the server answers a single request per
    // connection, which keeps both ends free of reconnect bookkeeping. A
    // turn's latency is dominated by the model anyway.
    final controller = StreamController<ChatEvent>();
    WebSocketChannel? channel;
    var terminal = false;

    void emit(ChatEvent event) {
      if (controller.isClosed) return;
      controller.add(event);
      if (event is ChatDoneEvent || event is ChatErrorEvent) {
        terminal = true;
        channel?.sink.close();
        controller.close();
      }
    }

    controller.onListen = () {
      final sessionToken = token;
      if (sessionToken == null) {
        emit(const ChatErrorEvent('sign in to use chat'));
        return;
      }
      try {
        channel = WebSocketChannel.connect(_webSocketUri('/chat'));
        channel!.sink.add(
          jsonEncode({
            'token': sessionToken,
            'message': message,
            'history': [for (final m in history) m.toJson()],
            if (workspaceId != null && workspaceId.isNotEmpty)
              'workspace_id': workspaceId,
          }),
        );
        channel!.stream.listen(
          (frame) {
            try {
              final decoded = jsonDecode(frame as String);
              if (decoded is Map<String, dynamic>) {
                final event = ChatEvent.fromJson(decoded);
                if (event != null) emit(event);
              }
            } catch (_) {
              // Ignore malformed frames; the terminal frame settles the turn.
            }
          },
          onDone: () {
            if (!terminal) emit(const ChatErrorEvent('connection lost'));
          },
          onError: (Object _) {
            if (!terminal) emit(const ChatErrorEvent('connection lost'));
          },
        );
      } catch (_) {
        emit(const ChatErrorEvent('could not reach the server'));
      }
    };
    controller.onCancel = () {
      terminal = true;
      channel?.sink.close();
    };
    return controller.stream;
  }
}
