part of 'home_screen.dart';

// Printable keys use CharacterActivator so they match what the keystroke
// actually produced on any layout ("/" is Shift+7 on Swiss keyboards), and
// _HomeAction suppresses them while a text field has focus, the event then
// falls through unhandled and the letter is typed instead of firing a
// shortcut. Chords and Escape (whileTyping: true) stay live during typing; the
// quick-add bar consumes its own Escape before it ever bubbles up here.
const _homeShortcuts = <ShortcutActivator, Intent>{
  CharacterActivator('c'): _NewNoteIntent(),
  CharacterActivator('n'): _NewNoteIntent(),
  CharacterActivator('l'): _NewNoteIntent(NoteKind.checklist),
  CharacterActivator('m'): _NewNoteIntent(NoteKind.markdown),
  CharacterActivator('d'): _NewNoteIntent(NoteKind.drawing),
  CharacterActivator('t'): _NewNoteIntent(NoteKind.tracker),
  CharacterActivator('/'): _FocusSearchIntent(),
  CharacterActivator('?'): _ShortcutHelpIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, control: true): _FocusSearchIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.keyK, meta: true): _FocusSearchIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.keyG, control: true): _ToggleLayoutIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.keyG, meta: true): _ToggleLayoutIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(whileTyping: true),
};

abstract class _HomeIntent extends Intent {
  const _HomeIntent({this.whileTyping = false});

  final bool whileTyping;
}

class _NewNoteIntent extends _HomeIntent {
  const _NewNoteIntent([this.kind]);

  /// Null starts the user's default kind.
  final NoteKind? kind;
}

class _FocusSearchIntent extends _HomeIntent {
  const _FocusSearchIntent({super.whileTyping});
}

class _EscapeIntent extends _HomeIntent {
  const _EscapeIntent({super.whileTyping});
}

class _ToggleLayoutIntent extends _HomeIntent {
  const _ToggleLayoutIntent({super.whileTyping});
}

class _ShortcutHelpIntent extends _HomeIntent {
  const _ShortcutHelpIntent();
}

/// Runs a home-screen shortcut unless the binding defers to an active text
/// field. A disabled action leaves the key event unhandled, which is what
/// lets the character reach the field instead of being swallowed.
class _HomeAction<T extends _HomeIntent> extends CallbackAction<T> {
  _HomeAction({required super.onInvoke});

  @override
  bool isEnabled(T intent) => intent.whileTyping || !_editingText;

  static bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;
}
