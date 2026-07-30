import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/motion.dart';
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
  // Set when the turn created or appended to a note (the chat write path).
  ChatCreatedEvent? created;

  _Turn.user(this.text) : role = 'user', sources = const [], streaming = false;
  _Turn.pending()
    : role = 'assistant',
      text = '',
      sources = const [],
      streaming = true;
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Turn> _turns = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<ChatEvent>? _sub;

  bool get _busy => _turns.isNotEmpty && _turns.last.streaming;

  @override
  void initState() {
    super.initState();
    // Focusing the composer right away brings the soft keyboard up while the
    // page is still sliding in, which stutters the open animation. Wait for
    // the route transition to settle, then focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _inputFocus.requestFocus();
        return;
      }
      void onStatus(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          animation.removeStatusListener(onStatus);
          if (mounted) _inputFocus.requestFocus();
        }
      }

      animation.addStatusListener(onStatus);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    // Submitting via the keyboard (TextInputAction.send) unfocuses the field
    // by default, and the send button steals focus on click, take it back
    // first so the user can just keep typing, whatever happens below.
    _inputFocus.requestFocus();
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
    // Answer over the workspace the user is looking at, and file anything the
    // turn writes there too.
    _sub = api
        .chat(
          message,
          history,
          workspaceId: context.read<NotesStore>().activeWorkspaceId,
        )
        .listen(
          (event) => _handle(pending, event),
          onError: (Object _) =>
              _handle(pending, const ChatErrorEvent('connection lost')),
          // The ApiClient always closes with done/error, but if a stream ever
          // ends without one, don't leave the turn (and the send button)
          // stuck streaming forever.
          onDone: () {
            if (pending.streaming) {
              _handle(pending, const ChatErrorEvent('connection lost'));
            }
          },
        );
  }

  /// Start over: drop the conversation (it lives in memory only) and cancel
  /// any in-flight reply. Whatever's typed in the composer survives.
  void _newConversation() {
    _sub?.cancel();
    _sub = null;
    setState(() => _turns.clear());
    _inputFocus.requestFocus();
  }

  void _handle(_Turn turn, ChatEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case ChatSourcesEvent(:final notes):
          turn.sources = notes;
        case ChatCreatedEvent():
          turn.created = event;
          // Pull the new/updated note into the local store now so the grid
          // reflects it and the chip can label it, the WS change nudge would
          // do this too, a moment later.
          context.read<NotesStore>().load();
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
      openFullscreen: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => EditorScreen(noteId: id))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat with your notes'),
        actions: [
          IconButton(
            tooltip: 'New conversation',
            onPressed: _turns.isEmpty ? null : _newConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
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
                        itemBuilder: (context, index) {
                          final turn = _turns[_turns.length - 1 - index];
                          return _Bubble(
                            key: ObjectKey(turn),
                            turn: turn,
                            onOpenNote: _openNote,
                          );
                        },
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
                        // Never disabled: disabling while the answer streams
                        // tears down the engine's text editing element, and
                        // (on Firefox) focus doesn't survive the re-enable,
                        // the composer went dead after the first reply. The
                        // user can type the follow-up during streaming; only
                        // sending is gated on _busy.
                        child: TextField(
                          controller: _input,
                          focusNode: _inputFocus,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: 'Ask about your notes…',
                            filled: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(kRadius),
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
                      Tooltip(
                        message: 'Send',
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: FilledButton(
                            onPressed: _busy ? null : _send,
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(EdgeInsets.zero),
                              minimumSize: WidgetStatePropertyAll(Size(48, 48)),
                              shape: WidgetStatePropertyAll(kRoundedShape),
                            ),
                            child: const Icon(Icons.arrow_upward),
                          ),
                        ),
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
            Icon(
              Icons.forum_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Ask about your notes, answers cite the notes they came from. '
              'You can also ask to create a note or add to one.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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

  const _Bubble({super.key, required this.turn, required this.onOpenNote});

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
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failedEmpty)
            Text(turn.error!, style: TextStyle(color: scheme.onErrorContainer))
          else if (turn.text.isEmpty && turn.streaming)
            const _TypingDots()
          else if (!isUser)
            MarkdownBody(
              data: turn.text,
              selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
              onTapLink: (text, href, title) {
                final uri = href == null ? null : Uri.tryParse(href);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            )
          else
            Text(turn.text),
          if (turn.error != null && turn.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Interrupted: ${turn.error}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );

    final sourcesChips = turn.sources.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
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
          );

    final createdChip = switch (turn.created) {
      final created? => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ActionChip(
          avatar: Icon(
            created.action == 'append'
                ? Icons.playlist_add
                : Icons.note_add_outlined,
            size: 16,
          ),
          label: Text(
            '${created.action == 'append' ? 'Updated' : 'Created'}: '
            '${_chipLabel(created.note, store)}',
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => onOpenNote(created.note.id),
        ),
      ),
      null => const SizedBox.shrink(),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: _entrance(
        context,
        Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            _reveal(context, visible: turn.sources.isNotEmpty, child: sourcesChips),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: bubble,
            ),
            _reveal(context, visible: turn.created != null, child: createdChip),
          ],
        ),
      ),
    );
  }

  /// Fades and rises a freshly-added bubble in; a turn already on screen
  /// (its text growing while it streams) keeps this animation's Tween
  /// unchanged across rebuilds, so it never replays.
  Widget _entrance(BuildContext context, Widget child) {
    if (Motion.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.base,
      curve: Motion.emphasized,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 10),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// Grows and fades a bubble-local extra (source chips, the created-note
  /// chip) in when it first appears, instead of popping the bubble's layout.
  Widget _reveal(BuildContext context, {required bool visible, required Widget child}) {
    return AnimatedSize(
      duration: Motion.base,
      curve: Motion.standard,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: Motion.base,
        switchInCurve: Motion.standard,
        switchOutCurve: Motion.standard,
        child: KeyedSubtree(
          key: ValueKey(visible),
          child: visible ? child : const SizedBox.shrink(),
        ),
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
