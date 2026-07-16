/// Wire types for the notes-chat WebSocket (`GET /api/chat?token=`).
///
/// One request per connection: the client sends `{message, history}`, the
/// server replies with a `sources` frame, zero or more `delta` frames, and a
/// terminal `done` or `error` frame.
library;

/// One prior turn sent back to the server as conversation history.
class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;

  const ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// A note the answer drew from; rendered as a tappable chip.
class ChatSource {
  final String id;
  final String title;

  const ChatSource({required this.id, required this.title});

  factory ChatSource.fromJson(Map<String, dynamic> json) => ChatSource(
    id: json['id'] as String,
    title: (json['title'] as String?) ?? '',
  );
}

/// A parsed server frame.
sealed class ChatEvent {
  const ChatEvent();

  /// Returns null for frames of unknown type, so protocol additions never
  /// break older clients.
  static ChatEvent? fromJson(Map<String, dynamic> json) => switch (json['type']) {
    'sources' => ChatSourcesEvent([
      for (final note in (json['notes'] as List? ?? []))
        if (note is Map<String, dynamic>) ChatSource.fromJson(note),
    ]),
    'delta' => ChatDeltaEvent((json['text'] as String?) ?? ''),
    'done' => const ChatDoneEvent(),
    'error' => ChatErrorEvent((json['message'] as String?) ?? 'unknown error'),
    _ => null,
  };
}

class ChatSourcesEvent extends ChatEvent {
  final List<ChatSource> notes;
  const ChatSourcesEvent(this.notes);
}

class ChatDeltaEvent extends ChatEvent {
  final String text;
  const ChatDeltaEvent(this.text);
}

class ChatDoneEvent extends ChatEvent {
  const ChatDoneEvent();
}

class ChatErrorEvent extends ChatEvent {
  final String message;
  const ChatErrorEvent(this.message);
}
