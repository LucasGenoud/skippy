import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat.dart';
import '../models/note.dart';

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
  // auth
  Future<({String token, AuthUser user})> register(
    String username,
    String password,
  );
  Future<({String token, AuthUser user})> login(
    String username,
    String password,
  );
  Future<void> logout();
  Future<AuthUser> me();

  // notes
  Future<List<Note>> fetchNotes();
  Future<void> createNote(Note note);
  Future<void> patchNote(String id, Map<String, dynamic> fields);
  Future<void> deleteNote(String id);
  Future<void> reorderNotes(List<String> ids);

  /// A note's edit history, newest first.
  Future<List<NoteVersion>> fetchNoteVersions(String noteId);

  /// Roll a note's content back to a past version; returns the updated note.
  /// The server checkpoints the pre-restore state, so this is reversible.
  Future<Note> restoreNoteVersion(String noteId, String versionId);

  /// Previously checked item texts, grouped per note id, most used first.
  /// Suggestions are scoped per note — one note's history never leaks into
  /// another's rows.
  Future<Map<String, List<String>>> fetchChecklistHistory();

  // labels
  Future<List<Label>> fetchLabels();
  Future<void> createLabel(String id, String name);
  Future<void> renameLabel(String id, String name);
  Future<void> deleteLabel(String id);

  // sharing
  Future<Note> addCollaborator(String noteId, String username);
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

  // per-user settings (opaque JSON document, synced across devices)
  Future<Map<String, dynamic>> fetchSettings();
  Future<void> putSettings(Map<String, dynamic> settings);

  /// Meaning-based search; returns note ids ranked by similarity.
  /// Throws [ApiException] (503) when the server has it disabled.
  Future<List<String>> semanticSearch(String query, {int limit = 20});

  /// Which optional, service-backed features this server has enabled. Drives
  /// whether the audio recorder and semantic-search toggle appear at all.
  Future<({bool semanticSearch, bool audioTranscription})> fetchCapabilities();

  /// Ask the server to (re)transcribe an audio note's clip. Used to retry a
  /// failed transcription.
  Future<void> transcribeNote(String noteId);

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

  /// One notes-chat turn: sends [message] with prior [history] and emits the
  /// server's frames (sources, streamed deltas, then done/error). The stream
  /// closes after the terminal event.
  Stream<ChatEvent> chat(String message, List<ChatMessage> history);
}

class ApiClient implements Api {
  /// Resolution order: --dart-define=API_BASE, then same-origin when the app
  /// is served by the Rust binary itself, then the local dev default.
  static String defaultBaseUrl() {
    const fromEnv = String.fromEnvironment('API_BASE');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (kIsWeb && Uri.base.port == 8787) return Uri.base.origin;
    return 'http://localhost:8787';
  }

  String baseUrl;
  final http.Client _client = http.Client();

  /// Session token; set by the auth store after sign-in.
  String? token;

  /// Invoked when the server rejects our session (expired/revoked token).
  VoidCallback? onUnauthorized;

  ApiClient({String? baseUrl}) : baseUrl = baseUrl ?? defaultBaseUrl();

  Uri _uri(String path) => Uri.parse('$baseUrl/api$path');

  Map<String, String> _headers({bool json = true}) => {
    if (json) 'content-type': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  };

  dynamic _decode(http.Response res, {bool authed = true}) {
    if (res.statusCode == 401 && authed) {
      onUnauthorized?.call();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  // -- auth ----------------------------------------------------------------

  Future<({String token, AuthUser user})> _authCall(
    String path,
    String username,
    String password,
  ) async {
    final data =
        _decode(
              await _client.post(
                _uri(path),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({'username': username, 'password': password}),
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
    String username,
    String password,
  ) => _authCall('/auth/register', username, password);

  @override
  Future<({String token, AuthUser user})> login(
    String username,
    String password,
  ) => _authCall('/auth/login', username, password);

  @override
  Future<void> logout() async {
    _decode(
      await _client.post(_uri('/auth/logout'), headers: _headers()),
      authed: false,
    );
  }

  @override
  Future<AuthUser> me() async {
    final data = _decode(
      await _client.get(_uri('/auth/me'), headers: _headers()),
    );
    return AuthUser.fromJson(data as Map<String, dynamic>);
  }

  // -- notes ---------------------------------------------------------------

  @override
  Future<List<Note>> fetchNotes() async {
    final data =
        _decode(await _client.get(_uri('/notes'), headers: _headers())) as List;
    return data.map((j) => Note.fromJson(j as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> createNote(Note note) async {
    _decode(
      await _client.post(
        _uri('/notes'),
        headers: _headers(),
        body: jsonEncode({
          'id': note.id,
          'kind': note.kind.wire,
          'title': note.title,
          'content': note.content,
          'items': Note.itemsToJson(note.items),
          'color': note.color,
          'pinned': note.pinned,
          'position': note.position,
          if (note.reminderAt != null)
            'reminder_at': note.reminderAt!.toUtc().toIso8601String(),
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

  // -- labels ---------------------------------------------------------------

  @override
  Future<List<Label>> fetchLabels() async {
    final data =
        _decode(await _client.get(_uri('/labels'), headers: _headers()))
            as List;
    return data.map((j) => Label.fromJson(j as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> createLabel(String id, String name) async {
    _decode(
      await _client.post(
        _uri('/labels'),
        headers: _headers(),
        body: jsonEncode({'id': id, 'name': name}),
      ),
    );
  }

  @override
  Future<void> renameLabel(String id, String name) async {
    _decode(
      await _client.patch(
        _uri('/labels/$id'),
        headers: _headers(),
        body: jsonEncode({'name': name}),
      ),
    );
  }

  @override
  Future<void> deleteLabel(String id) async {
    _decode(await _client.delete(_uri('/labels/$id'), headers: _headers()));
  }

  // -- sharing ----------------------------------------------------------------

  @override
  Future<Note> addCollaborator(String noteId, String username) async {
    final data = _decode(
      await _client.post(
        _uri('/notes/$noteId/collaborators'),
        headers: _headers(),
        body: jsonEncode({'username': username}),
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
    final streamed = await _client.send(request);
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
  Future<List<String>> semanticSearch(String query, {int limit = 20}) async {
    final uri = _uri(
      '/search',
    ).replace(queryParameters: {'q': query, 'limit': '$limit'});
    final data = _decode(await _client.get(uri, headers: _headers())) as List;
    return [for (final hit in data) (hit as Map)['note_id'] as String];
  }

  // -- capabilities & transcription --------------------------------------------

  @override
  Future<({bool semanticSearch, bool audioTranscription})>
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
      if (closed || token == null) return;
      final wsBase = baseUrl.replaceFirst('http', 'ws');
      try {
        channel = WebSocketChannel.connect(
          Uri.parse('$wsBase/api/ws?token=$token'),
        );
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
  Stream<ChatEvent> chat(String message, List<ChatMessage> history) {
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
      final wsBase = baseUrl.replaceFirst('http', 'ws');
      try {
        channel = WebSocketChannel.connect(
          Uri.parse('$wsBase/api/chat?token=$token'),
        );
        channel!.sink.add(
          jsonEncode({
            'message': message,
            'history': [for (final m in history) m.toJson()],
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
