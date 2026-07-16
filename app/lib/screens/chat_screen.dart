import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import 'editor_screen.dart';

/// Ask questions about your notes. Each turn the server retrieves the most
/// relevant notes (semantic search over the same embeddings the ✨ search
/// uses), hands them to the user's configured LLM, and streams the answer
/// back; the notes it drew from render as tappable chips above the reply.
/// The conversation lives in memory only and is discarded on close.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  /// Push over whatever's on screen (root navigator, so it also works from
  /// the wide-screen editor modal).
  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (_) => const ChatScreen()));
  }

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// One bubble: a user question or an (possibly still streaming) answer.
class _Turn {
  final String role; // 'user' | 'assistant'
  String text;
  List<ChatSource> sources;
  bool streaming;
  String? error;

  _Turn.user(this.text) : role = 'user', sources = const [], streaming = false;
  _Turn.pending() : role = 'assistant', text = '', sources = const [], streaming = true;
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Turn> _turns = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<ChatEvent>? _sub;

  bool get _busy => _turns.isNotEmpty && _turns.last.streaming;

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final message = _input.text.trim();
    if (message.isEmpty || _busy) return;
    // History = every completed turn before this one (errors excluded so a
    // failed half-answer doesn't poison the next turn).
    final history = [
      for (final t in _turns)
        if (!t.streaming && t.error == null && t.text.isNotEmpty)
          ChatMessage(role: t.role, content: t.text),
    ];
    final pending = _Turn.pending();
    setState(() {
      _turns.add(_Turn.user(message));
      _turns.add(pending);
      _input.clear();
    });
    final api = context.read<SettingsStore>().api;
    _sub = api
        .chat(message, history)
        .listen(
          (event) => _handle(pending, event),
          onError: (Object _) =>
              _handle(pending, const ChatErrorEvent('connection lost')),
        );
    _inputFocus.requestFocus();
  }

  void _handle(_Turn turn, ChatEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case ChatSourcesEvent(:final notes):
          turn.sources = notes;
        case ChatDeltaEvent(:final text):
          turn.text += text;
        case ChatDoneEvent():
          turn.streaming = false;
        case ChatErrorEvent(:final message):
          turn.streaming = false;
          turn.error = message;
      }
    });
  }

  void _openNote(String id) {
    openNoteEditor(
      context,
      noteId: id,
      // Narrow layouts get a plain fullscreen push (there's no enclosing
      // OpenContainer to morph from on this screen).
      openFullscreen: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EditorScreen(noteId: id)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat with your notes')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              Expanded(
                child: _turns.isEmpty
                    ? _EmptyHint(scheme: scheme)
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        itemCount: _turns.length,
                        itemBuilder: (context, index) => _Bubble(
                          turn: _turns[_turns.length - 1 - index],
                          onOpenNote: _openNote,
                        ),
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          focusNode: _inputFocus,
                          enabled: !_busy,
                          autofocus: true,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: 'Ask about your notes…',
                            filled: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Send',
                        onPressed: _busy ? null : _send,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final ColorScheme scheme;
  const _EmptyHint({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Ask about your notes — answers cite the notes they came from.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Turn turn;
  final ValueChanged<String> onOpenNote;

  const _Bubble({required this.turn, required this.onOpenNote});

  /// Chip text for a source note: its title, else the first line of its
  /// locally cached content, else "Untitled".
  static String _chipLabel(ChatSource source, NotesStore store) {
    if (source.title.trim().isNotEmpty) return source.title.trim();
    final content = store.noteById(source.id)?.content.trim() ?? '';
    if (content.isEmpty) return 'Untitled';
    final line = content.split('\n').first;
    return line.length > 40 ? '${line.substring(0, 40)}…' : line;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.watch<NotesStore>();
    final isUser = turn.role == 'user';

    // Failed before any text arrived: the error IS the bubble. Otherwise the
    // partial answer stays and the error trails it.
    final failedEmpty = turn.error != null && turn.text.isEmpty;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser
            ? scheme.primaryContainer
            : failedEmpty
            ? scheme.errorContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failedEmpty)
            Text(turn.error!, style: TextStyle(color: scheme.onErrorContainer))
          else if (turn.text.isEmpty && turn.streaming)
            const _TypingDots()
          else
            Text(turn.text),
          if (turn.error != null && turn.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '— interrupted: ${turn.error}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.error,
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (turn.sources.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final source in turn.sources)
                  ActionChip(
                    avatar: const Icon(Icons.sticky_note_2_outlined, size: 16),
                    label: Text(
                      _chipLabel(source, store),
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => onOpenNote(source.id),
                  ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: bubble,
          ),
        ],
      ),
    );
  }
}

/// Three pulsing dots while the first token is on its way.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Opacity(
                // Each dot pulses on a phase-shifted triangle wave.
                opacity:
                    0.25 +
                    0.75 *
                        (1 - ((_controller.value + i / 3) % 1 * 2 - 1).abs()),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
