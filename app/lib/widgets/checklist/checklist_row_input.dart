part of 'animated_checklist.dart';

// The text-input mechanics of one checklist row: what it takes for a row's
// field to report every edit, including a backspace on an empty row, across
// soft keyboards, iOS, and the browser.

/// Parked in an empty row while it holds focus, so backspace has something to
/// delete. A field that is already empty absorbs the keypress silently on soft
/// keyboards and in the browser's text input: nothing is deleted, so nothing
/// is reported, and the row never learns it was asked to go away. With the
/// marker in place the same keypress arrives as an ordinary edit (the text
/// goes from the marker to nothing), which is the signal to remove the row.
/// It is a zero-width space, so it never shows, and [_stripMarker] keeps it
/// from ever reaching the note.
const _kEmptyRowMarker = '\u200b';

String _withoutMarker(String text) => text.replaceAll(_kEmptyRowMarker, '');

/// Repairs a malformed transition iOS can send when a quickly typed word is
/// committed and Space is pressed immediately afterwards. The input client
/// sometimes reports only the newly inserted space as the field's complete
/// value, even though the old value still has a collapsed caret after the
/// word. Treat that one narrow shape as the insertion it describes. A real
/// replacement carries a non-collapsed old selection and passes through.
final _keepCommittedWordBeforeSpace = TextInputFormatter.withFunction((
  oldValue,
  newValue,
) {
  if (newValue.text != ' ' ||
      oldValue.text.isEmpty ||
      !oldValue.selection.isValid ||
      !oldValue.selection.isCollapsed) {
    return newValue;
  }
  final offset = oldValue.selection.baseOffset.clamp(0, oldValue.text.length);
  final repaired = oldValue.text.replaceRange(offset, offset, newValue.text);
  return TextEditingValue(
    text: repaired,
    selection: TextSelection.collapsed(offset: offset + 1),
  );
});

/// Drops the marker inside the input pipeline, so the first character typed
/// over it lands in the controller already clean. Formatters run on platform
/// edits only, which is exactly right here: parking the marker is a
/// programmatic write and must survive, and a row never has to write to its
/// own controller from inside an edit callback (on iOS that write races the
/// keyboard's own copy of the field).
///
/// A field holding nothing but the marker is left exactly as parked. Input
/// clients report the field's value back at us for reasons of their own (the
/// browser's does it after every edit), and stripping the marker out of one of
/// those would turn it into an edit that empties the row: a phantom backspace
/// no one pressed.
final _stripMarker = TextInputFormatter.withFunction((oldValue, newValue) {
  final text = newValue.text;
  final stripped = _withoutMarker(text);
  if (stripped.isEmpty || stripped.length == text.length) return newValue;
  int shifted(int offset) => offset <= 0
      ? offset
      : _withoutMarker(text.substring(0, math.min(offset, text.length))).length;
  final selection = newValue.selection;
  return TextEditingValue(
    text: stripped,
    selection: selection.isValid
        ? TextSelection(
            baseOffset: shifted(selection.baseOffset),
            extentOffset: shifted(selection.extentOffset),
          )
        : selection,
    // Offsets moved, so whatever the client was composing no longer maps.
    composing: TextRange.empty,
  );
});

/// One row's text-editing state. The composer owns one of these too: it is an
/// ordinary row in every respect except that the item it writes into does not
/// exist until the first keystroke.
class _RowHandles {
  final TextEditingController controller;
  final FocusNode focusNode = FocusNode();
  final LayerLink link = LayerLink();

  /// Suggestions only appear once the user actually types in a row, not on
  /// mere focus. The composer is the exception: focusing it offers the whole
  /// history straight away.
  bool typedSinceFocus = false;

  /// Text this row has pushed up but not yet seen echoed back in
  /// [AnimatedChecklist.items]. Typing in a row deliberately doesn't rebuild
  /// the editor, so the list can lag a keystroke or two behind; until it
  /// catches up, its older value must not overwrite what's in the field.
  String? unacknowledged;

  /// Whether an edit that empties this row is a backspace on an already-empty
  /// row (and so removes it). Armed one frame after the marker is parked:
  /// input clients that report a stale empty value of their own, rather than
  /// a keypress, do so within the frame that wrote the marker, and must never
  /// take a row with them. See [_kEmptyRowMarker].
  bool emptyBackspaceArmed = false;

  /// Set the moment the row goes away. Callbacks that outlive a row (the
  /// deferred marker re-arm, the post-frame focus handoff) check it before
  /// touching a controller or focus node that is no longer there.
  bool disposed = false;

  /// What the field held before its text last changed, kept because an edit
  /// only says what the text has become. Selection-only updates (a tap, a
  /// select-all, the framework normalizing an invalid offset) refresh the
  /// current value without displacing it. See [emptiedByUser].
  TextEditingValue _previous = TextEditingValue.empty;
  TextEditingValue _current = TextEditingValue.empty;

  _RowHandles([String text = ''])
    : controller = TextEditingController(text: text) {
    _current = controller.value;
    controller.addListener(() {
      final value = controller.value;
      if (value.text != _current.text) _previous = _current;
      _current = value;
      // The marker is zero-width, so a tap at the very start of an empty row
      // can drop the caret in front of it, where backspace would again have
      // nothing to delete. Keep the caret on its far side.
      if (value.text != _kEmptyRowMarker) return;
      if (value.selection.isCollapsed && value.selection.baseOffset == 0) {
        controller.selection = const TextSelection.collapsed(
          offset: _kEmptyRowMarker.length,
        );
      }
    });
  }

  /// What the user has actually written in this row: the field's text minus
  /// the empty-row marker.
  String get text => _withoutMarker(controller.text);

  /// Whether the edit that just emptied this field is something the user did.
  /// Deleting the last character, or a selection that covered everything,
  /// empties a field; a caret resting mid-word cannot. A report that empties
  /// the field from under such a caret is the input client resetting it (a
  /// fresh attachment, a keyboard swap, its own copy catching up), and the
  /// word being typed must survive it.
  bool get emptiedByUser {
    final before = _previous;
    if (_withoutMarker(before.text).length <= 1) return true;
    final selection = before.selection;
    return !selection.isCollapsed &&
        selection.start == 0 &&
        selection.end == before.text.length;
  }

  void dispose() {
    disposed = true;
    controller.dispose();
    focusNode.dispose();
  }
}
