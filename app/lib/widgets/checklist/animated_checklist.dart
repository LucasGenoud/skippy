import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/note.dart';
import '../../theme.dart';
import '../../util/motion.dart';
import '../../util/platform.dart';
import '../all_done_burst.dart';
import '../reminder_chip.dart';
import '../measure_size.dart';
import 'checklist_suggestions.dart';
import 'pop_checkbox.dart';

/// Checklist editor:
///
/// * every row is absolutely positioned and glides when anything changes, so
///   checking an item visibly slides it down into the "checked" section;
/// * that section starts collapsed behind its "N checked items" header, so
///   opening a long-lived list shows what is still to do rather than a wall
///   of struck-through history, one tap unfolds it;
/// * rows have a drag handle for reordering (immediate drag, no long-press);
/// * the last unchecked row is the composer: the first keystroke in it
///   creates the item it is writing, and the caret stays where it is, so
///   nothing about the platform's text input is torn down mid-word;
/// * typing in a row opens a suggestion popup anchored under the caret row,
///   fed by the user's checked-item history, with the matched prefix bolded.
class AnimatedChecklist extends StatefulWidget {
  final List<ChecklistItem> items;

  /// Reminders on individual rows, keyed by item id. A checked row never has
  /// one: the store and the server both drop it as the box is ticked.
  final Map<String, ItemReminder> reminders;
  final bool readOnly;
  final bool autofocusNew;
  final String highlightQuery;
  final List<String> Function(String query, Set<String> exclude) suggestionsFor;
  final void Function(String itemId) onToggle;
  final void Function(String itemId, String text) onItemTextChanged;
  final void Function(String itemId) onRemove;

  /// Creates a new item at the end of the list and returns its id, so the
  /// composer can go on writing into the row it just spawned.
  final String Function(String text) onAdd;
  final void Function(List<ChecklistItem> newItems) onReorderItems;

  /// Enter in a row inserts a fresh empty row right below it;
  /// returns the new item's id so it can be focused.
  final String Function(String afterItemId)? onInsertAfter;

  /// Opens the reminder picker for one row. Null leaves the affordance out
  /// entirely, which is what the quick-add composer wants: its rows belong to
  /// a note that does not exist yet.
  final void Function(String itemId)? onSetReminder;

  const AnimatedChecklist({
    super.key,
    required this.items,
    required this.suggestionsFor,
    required this.onToggle,
    required this.onItemTextChanged,
    required this.onRemove,
    required this.onAdd,
    required this.onReorderItems,
    this.onInsertAfter,
    this.onSetReminder,
    this.reminders = const {},
    this.readOnly = false,
    this.autofocusNew = false,
    this.highlightQuery = '',
  });

  @override
  State<AnimatedChecklist> createState() => _AnimatedChecklistState();
}

/// The composer (the last, always-present row) and the collapsed-section
/// header are laid out alongside the items, so they need ids of their own.
const _kComposerId = '__new__';
const _kHeaderId = '__header__';

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

/// The vertical rhythm of a row. Every control is centred in a band
/// [bandHeight] tall and the field is padded by [textPadding], which puts the
/// middle of its first line exactly in the middle of that band. A one-line
/// item is therefore centred in its row, and a wrapped one keeps the same
/// first line: later lines grow below the controls instead of dragging them
/// down to the centre of the whole item.
class _RowMetrics {
  final double bandHeight;
  final double textPadding;

  const _RowMetrics({required this.bandHeight, required this.textPadding});
}

class _AnimatedChecklistState extends State<AnimatedChecklist> {
  /// A one-line item and the composer are this tall. Rows may grow beyond it
  /// when their text wraps.
  static const double _minimumRowHeight = 48;

  /// The checked-section header follows the text scale, so it is measured
  /// like the rows; this is what it takes up until it has been.
  static const double _estimatedHeaderHeight = 40;

  final Map<String, _RowHandles> _handles = {};
  final Map<String, double> _rowHeights = {};
  final Set<String> _enteringIds = {};
  late final _RowHandles _composer = _RowHandles();
  final OverlayPortalController _popup = OverlayPortalController();
  final ScrollController _suggestionsScroll = ScrollController();

  /// Bumped whenever the popup's inputs change (the focused row's text, or
  /// which row is focused). The popup listens to this instead of riding a
  /// `setState`, so a keystroke rebuilds one overlay, not thirty rows, each
  /// a TextField with its own gesture, focus and ink machinery.
  final ValueNotifier<int> _popupRevision = ValueNotifier(0);

  /// Which row the pointer is over, and which one holds the caret. Notifiers,
  /// not plain state, for the same reason as [_popupRevision]: see the note in
  /// `_itemRow`.
  final ValueNotifier<String?> _hovered = ValueNotifier(null);
  final ValueNotifier<String?> _focusedId = ValueNotifier(null);

  List<String> _uncheckedOrder = [];

  /// [AnimatedChecklist.items] indexed by id, and the checked ones in order.
  /// Derived once per item change instead of by rescanning the list for every
  /// row, which made each build of a long checklist a quadratic walk.
  Map<String, ChecklistItem> _byId = const {};
  List<ChecklistItem> _checked = const [];

  /// Built rows, kept across our own rebuilds. A row is a TextField with its
  /// own focus, gesture and ink machinery plus an animated checkbox, while a
  /// drag step, a caret move or a store refresh changes where rows sit, not
  /// what they hold. Handing back the same instances lets the framework skip
  /// those subtrees outright (`Element.updateChild` short-circuits on an
  /// identical widget). An entry is dropped when its item changes, and all of
  /// them when anything else a row is built from does.
  final Map<String, Widget> _rows = {};
  final Map<String, ChecklistItem> _rowItems = {};

  /// Text metrics are the same for every row, so they are measured once per
  /// theme/text-scale rather than once per row per build.
  _RowMetrics? _metrics;

  /// The item the composer is writing into, created by its first keystroke.
  /// It is drawn by the composer rather than as a row of its own, and set
  /// exactly while the composer holds text.
  String? _composingId;

  String? _draggingId;
  String? _pendingFocusId;
  double _dragY = 0;
  bool _snapFrame = true;

  /// Checked items fold away behind their header until asked for: a list that
  /// has been in use for a while is mostly history, and neither the reader nor
  /// the layout should have to carry it on every open.
  bool _showChecked = false;

  /// Whether the "all done" burst is currently playing, and which one: the
  /// counter keys the burst widget, so finishing a list again while the last
  /// flourish is still in the air restarts it instead of being swallowed.
  bool _celebrating = false;
  int _celebration = 0;

  @override
  void initState() {
    super.initState();
    _syncItems();
    _refreshOrder();
    _composer.focusNode.addListener(_onComposerFocusChange);
    // Backspace in an empty composer steps back up to the line above, the same
    // as in any other empty row. Hardware keyboards get here; where the
    // keypress never surfaces as a key event, the empty-row marker catches it
    // as an edit instead (see [_composerChanged]).
    _composer.focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.backspace &&
          _composer.text.isEmpty &&
          !widget.readOnly &&
          _focusRowAboveComposer()) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _popup.show();
      // Ask for focus outright rather than leaning on the composer's
      // `autofocus`. Flutter only honours autofocus when nothing in the
      // enclosing scope is focused yet, true inside the editor's own route,
      // but not on the home page, where the shortcut plumbing's page focus
      // already holds it and the quick-add checklist opened with no caret.
      if (widget.autofocusNew) _requestComposerFocusWhenReady();
    });
  }

  @override
  void dispose() {
    for (final handles in _handles.values) {
      handles.dispose();
    }
    _composer.dispose();
    _suggestionsScroll.dispose();
    _popupRevision.dispose();
    _hovered.dispose();
    _focusedId.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rows bake in colours and text metrics; a theme or text-scale change is
    // the one thing that alters every one of them at once.
    _metrics = null;
    _invalidateRows();
  }

  @override
  void didUpdateWidget(AnimatedChecklist oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncItems();
    // The only other things a row reads at build time. Its callbacks are read
    // when they fire, so a fresh closure from the parent doesn't stale a row.
    if (oldWidget.readOnly != widget.readOnly ||
        oldWidget.highlightQuery != widget.highlightQuery ||
        !mapEquals(oldWidget.reminders, widget.reminders)) {
      _invalidateRows();
    }
    final ids = {for (final item in widget.items) item.id};
    // The composed item went away underneath us (an undo, or another device):
    // the composer has nothing to write into any more.
    if (_composingId != null && !ids.contains(_composingId)) {
      _composingId = null;
    }
    // A drag reorders the list locally and only pushes the result up on drop,
    // so until then the local order wins.
    _refreshOrder(keepLocalOrder: _draggingId != null);
    // A row that is about to receive the caret must be stable immediately.
    // Fading/sliding that TextField while focus is handed to it makes the
    // first few characters feel like a dropped frame. The composed item is
    // already on screen (in the composer), so it does not "enter" either.
    // Other additions (for example a picked suggestion) still get the
    // decorative entrance.
    final oldIds = {for (final item in oldWidget.items) item.id};
    _enteringIds.addAll(
      ids
          .difference(oldIds)
          .where((id) => id != _pendingFocusId && id != _composingId),
    );
    final stale = _handles.keys.where((id) => !ids.contains(id)).toList();
    for (final id in stale) {
      _handles.remove(id)?.dispose();
    }
    _rows.removeWhere((id, _) => !ids.contains(id));
    _rowItems.removeWhere((id, _) => !ids.contains(id));
    _rowHeights.removeWhere(
      (id, _) => !ids.contains(id) && id != _kHeaderId && id != _kComposerId,
    );
    _enteringIds.removeWhere((id) => !ids.contains(id));
  }

  void _syncItems() {
    _byId = {for (final item in widget.items) item.id: item};
    _checked = [
      for (final item in widget.items)
        if (item.done) item,
    ];
  }

  void _invalidateRows() {
    _rows.clear();
    _rowItems.clear();
  }

  /// The unchecked rows, in display order. [AnimatedChecklist.items] is the
  /// source of truth, except for the item the composer is writing (drawn by
  /// the composer) and, mid-drag, for the order itself.
  void _refreshOrder({bool keepLocalOrder = false}) {
    final ids = [
      for (final item in widget.items)
        if (!item.done && item.id != _composingId) item.id,
    ];
    if (!keepLocalOrder) {
      _uncheckedOrder = ids;
      return;
    }
    final live = ids.toSet();
    final known = _uncheckedOrder.toSet();
    _uncheckedOrder = [
      for (final id in _uncheckedOrder)
        if (live.contains(id)) id,
      for (final id in ids)
        if (!known.contains(id)) id,
    ];
  }

  // -------------------------------------------------------------------
  // Focus

  /// Focusing the composer the instant a brand-new checklist note is still
  /// mid open-transition (container morph / fade-scale modal) makes iOS raise
  /// the keyboard while that animation is still running: the two fight, and
  /// the first keystrokes can be dropped before the platform's text input
  /// connection has caught up, taking the first word with them. Mirrors
  /// EditorScreen's `_focusBodyAfterOpen` for the plain-text body. The
  /// quick-add bar's embedded checklist has no route transition of its own
  /// (its enclosing route, the home page, is already fully open), so this
  /// still focuses immediately there.
  void _requestComposerFocusWhenReady() {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _composer.focusNode.requestFocus();
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeStatusListener(onStatus);
      if (mounted && status == AnimationStatus.completed) {
        _composer.focusNode.requestFocus();
      }
    }

    animation.addStatusListener(onStatus);
  }

  void _onComposerFocusChange() {
    if (!mounted) return;
    if (_composer.focusNode.hasFocus) {
      // An empty composer needs the marker as much as an empty row does: it
      // is what makes the next backspace something a soft keyboard reports.
      _armEmptyMarker(_composer);
    } else {
      _clearEmptyMarker(_composer);
      // Leaving the composer settles whatever it was writing: the row it made
      // becomes an ordinary row of the list.
      _commitComposing();
    }
    _onAnyFocusChange();
  }

  /// Walks the caret from the composer to the end of the last item, for a
  /// backspace with nothing left to delete. Nothing is removed on the way:
  /// unlike a row, the composer holds no item of its own, and it stays where
  /// it is for the next thing to be written. Answers whether there was a line
  /// above to go to — with none, the keypress is not ours to take.
  bool _focusRowAboveComposer() {
    final target = _uncheckedOrder.lastOrNull;
    if (target == null || widget.readOnly) return false;
    _pendingFocusId = target;
    // Hand focus over inside the keypress itself, so a soft keyboard stays up;
    // the handoff then places the caret at the end of that line. Same reasoning
    // as [_focusNeighborThenRemove].
    _handles[target]?.focusNode.requestFocus();
    setState(() {});
    return true;
  }

  void _onAnyFocusChange() {
    if (!mounted) return;
    // Where the caret is only changes the affordances on the row holding it
    // and the suggestion popup. Rebuilding the whole list for it, twice per
    // move, once for the blur and once for the focus, is what made a long
    // checklist stutter as the caret walked down it.
    _focusedId.value = _focusedRowId();
    _popupRevision.value++;
  }

  String? _focusedRowId() {
    if (_composer.focusNode.hasFocus) return _kComposerId;
    for (final entry in _handles.entries) {
      if (entry.value.focusNode.hasFocus) return entry.key;
    }
    return null;
  }

  /// The row a caret should fall back to when [itemId] goes away: the line
  /// above it, or the composer when there is nothing above.
  String _rowAbove(String itemId) {
    final unchecked = _uncheckedOrder.indexOf(itemId);
    if (unchecked >= 0) {
      return unchecked > 0 ? _uncheckedOrder[unchecked - 1] : _kComposerId;
    }
    // Checked rows live in their own section, below the composer.
    final at = _checked.indexWhere((item) => item.id == itemId);
    return at > 0 ? _checked[at - 1].id : _kComposerId;
  }

  void _focusNeighborThenRemove(String itemId) {
    final target = _rowAbove(itemId);
    _pendingFocusId = target;
    // Hand the caret over *now*, inside the keypress that asked for it, rather
    // than after the rebuild: browsers only keep the on-screen keyboard up for
    // a focus move made within the gesture that triggered it, so a frame later
    // the keyboard drops and the caret is stranded. The row above is a
    // different field that is already on screen and ready to take focus;
    // [_scheduleFocusHandoff] still runs afterwards to place the caret in it.
    final handles = target == _kComposerId ? _composer : _handles[target];
    handles?.focusNode.requestFocus();
    widget.onRemove(itemId);
    setState(() {});
  }

  /// Move the caret into [_pendingFocusId] once that row exists: rows are
  /// created during the build this is called from, so the handoff waits for
  /// the frame to be done.
  void _scheduleFocusHandoff() {
    final id = _pendingFocusId;
    if (id == null) return;
    _pendingFocusId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final handles = id == _kComposerId ? _composer : _handles[id];
      if (handles == null || handles.disposed) return;
      handles.focusNode.requestFocus();
      // Land the caret at the end so continuing to type appends, never a
      // selection of the whole row (which would make the next keystroke
      // replace the text). On web/desktop the platform issues its own
      // select-all when a field gains focus a frame later, so re-assert the
      // collapsed caret on the following frame to win over it.
      void collapseCaret() {
        if (!mounted || handles.disposed || !handles.focusNode.hasFocus) return;
        handles.controller.selection = TextSelection.collapsed(
          offset: handles.controller.text.length,
        );
      }

      collapseCaret();
      WidgetsBinding.instance.addPostFrameCallback((_) => collapseCaret());
    });
  }

  // -------------------------------------------------------------------
  // The empty-row marker

  /// Park the marker in a row that is focused and empty, so the next backspace
  /// is something the platform reports (see [_kEmptyRowMarker]).
  void _armEmptyMarker(_RowHandles handles) {
    _parkMarker(handles);
    // Once more after the frame: parking it is a write into a field the
    // platform is also writing to (the marker goes in from inside the very
    // keystroke that emptied the row, and focus lands a microtask after it is
    // asked for), so a lost race would leave the row with nothing for the next
    // backspace to delete, and no way to remove itself.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _parkMarker(handles);
      // Only now may an empty edit remove the row: the marker is in the field
      // and the frame that put it there is on screen.
      handles.emptyBackspaceArmed =
          !handles.disposed && handles.controller.text == _kEmptyRowMarker;
    });
  }

  /// Put the marker in, if the row is still there, focused and empty.
  void _parkMarker(_RowHandles handles) {
    if (handles.disposed ||
        widget.readOnly ||
        !handles.focusNode.hasFocus ||
        handles.controller.text.isNotEmpty) {
      return;
    }
    handles.controller.value = const TextEditingValue(
      text: _kEmptyRowMarker,
      selection: TextSelection.collapsed(offset: _kEmptyRowMarker.length),
    );
  }

  /// Take it back out: the row is no longer both focused and empty.
  void _clearEmptyMarker(_RowHandles handles) {
    handles.emptyBackspaceArmed = false;
    if (handles.disposed || handles.controller.text != _kEmptyRowMarker) return;
    handles.controller.value = TextEditingValue.empty;
  }

  /// Whether an edit that leaves [handles] empty is the user backspacing over
  /// the marker, rather than an input client reporting an empty value of its
  /// own (a fresh attachment, or its copy of the field catching up). Those
  /// carry no caret, and never arrive in a later frame than the marker.
  bool _isEmptyRowBackspace(_RowHandles handles) =>
      handles.emptyBackspaceArmed &&
      handles.controller.selection.baseOffset >= 0;

  // -------------------------------------------------------------------
  // Row state

  _RowHandles _handleFor(ChecklistItem item) {
    final handles = _handles.putIfAbsent(
      item.id,
      () => _createHandles(item.id),
    );
    // Backspace on an already-empty row deletes it and moves the caret up.
    // Hardware keyboards get here first; where the keypress never surfaces as
    // a key event, the empty-row marker catches it as an edit instead.
    handles.focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.backspace &&
          handles.text.isEmpty &&
          !widget.readOnly) {
        _focusNeighborThenRemove(item.id);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    // Reflect external (collaborator/undo) edits without fighting the caret,
    // or our own not-yet-echoed keystrokes.
    if (handles.unacknowledged == item.text) handles.unacknowledged = null;
    if (handles.unacknowledged == null &&
        !handles.focusNode.hasFocus &&
        handles.controller.text != item.text) {
      handles.controller.text = item.text;
    }
    return handles;
  }

  _RowHandles _createHandles(String itemId) {
    final handles = _RowHandles(_byId[itemId]?.text ?? '');
    handles.focusNode.addListener(() {
      if (handles.focusNode.hasFocus) {
        _armEmptyMarker(handles);
        handles.typedSinceFocus = false;
      } else {
        _clearEmptyMarker(handles);
        // Losing the caret no longer rebuilds the row, so take in here what
        // a rebuild used to: an edit that landed while the caret was in the
        // way (a collaborator's, an undo) and was held back for it.
        final current = _byId[itemId];
        if (current != null &&
            handles.unacknowledged == null &&
            handles.controller.text != current.text) {
          handles.controller.text = current.text;
        }
      }
      _onAnyFocusChange();
    });
    return handles;
  }

  /// Put [text] back in a field an input client wiped on its own, with the
  /// caret at the end, and tell nobody: as far as the note is concerned
  /// nothing happened.
  void _restore(_RowHandles handles, String? text) {
    final value = text ?? '';
    if (handles.disposed || value.isEmpty) return;
    handles.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  /// An edit reported by the row holding [item].
  void _itemTextChanged(ChecklistItem item, _RowHandles handles, String value) {
    final text = _withoutMarker(value);
    final wasArmed = _isEmptyRowBackspace(handles);
    handles.emptyBackspaceArmed = false;
    if (text.isEmpty) {
      // Not the user's doing: put back what the row was holding.
      if (!handles.emptiedByUser) {
        _restore(handles, handles.unacknowledged ?? item.text);
        return;
      }
      // Backspace on a row that was already empty: take it away, caret and
      // all. The row's own text has to be empty too, so the keystroke that
      // merely emptied it can never also remove it.
      if (wasArmed && (handles.unacknowledged ?? item.text).isEmpty) {
        _focusNeighborThenRemove(item.id);
        return;
      }
      // Emptied by this keystroke, not by the one before it: re-arm so the
      // next backspace removes the row.
      _armEmptyMarker(handles);
    }
    handles.typedSinceFocus = true;
    handles.unacknowledged = text;
    widget.onItemTextChanged(item.id, text);
    // Only the suggestion popup depends on what was typed; the row itself is
    // already showing it.
    _popupRevision.value++;
  }

  // -------------------------------------------------------------------
  // The composer

  /// An edit reported by the composer. The first keystroke materializes the
  /// item, so it is on the grid instantly and nothing is lost if the note is
  /// closed mid-word; everything after it edits that same item. The caret
  /// never moves, which is what keeps a mobile keyboard from resetting the
  /// field underneath the word being typed.
  void _composerChanged(String value) {
    final text = _withoutMarker(value);
    final composingId = _composingId;
    final wasArmed = _isEmptyRowBackspace(_composer);
    _composer.emptyBackspaceArmed = false;
    _composer.typedSinceFocus = true;
    _popupRevision.value++;
    if (text.isEmpty) {
      // A whole word cannot vanish under a resting caret: that is the input
      // client resetting the field, not the user clearing it.
      if (composingId != null && !_composer.emptiedByUser) {
        _restore(
          _composer,
          _composer.unacknowledged ?? _byId[composingId]?.text,
        );
        return;
      }
      // Backspace on a composer that was already empty. There is nothing here
      // to delete, so the caret goes back up to the line above instead.
      if (composingId == null) {
        if (wasArmed && _focusRowAboveComposer()) return;
        _armEmptyMarker(_composer);
        return;
      }
      // Everything typed so far has been deleted: the half-written row goes
      // with it rather than leaving a blank line in the note. The composer
      // itself stays put, with the caret in it, and re-arms so the next
      // backspace is the one that steps up.
      _discardComposing();
      _armEmptyMarker(_composer);
      return;
    }
    _composer.unacknowledged = text;
    if (composingId == null) {
      _composingId = widget.onAdd(text);
      setState(() {});
      return;
    }
    widget.onItemTextChanged(composingId, text);
  }

  /// Hand the row the composer has been writing over to the list: it becomes
  /// an ordinary row and the composer starts empty again, one line lower,
  /// without the caret ever leaving it.
  void _commitComposing() {
    final id = _composingId;
    if (id == null) return;
    final text = _composer.text.trim();
    final pushed = _composer.unacknowledged ?? _byId[id]?.text;
    _releaseComposer();
    // Nothing but whitespace: don't leave a blank row behind in the note.
    if (text.isEmpty) {
      widget.onRemove(id);
    } else if (text != pushed) {
      widget.onItemTextChanged(id, text);
    }
    // The committed row takes the composer's place and the composer drops a
    // line. Animating that would slide the field the caret is in, so it
    // happens between two frames instead.
    _snapFrame = true;
    setState(() {});
  }

  /// Drop the row being written without committing it.
  void _discardComposing() {
    final id = _composingId;
    if (id == null) return;
    _releaseComposer();
    widget.onRemove(id);
    setState(() {});
  }

  /// Empty the composer and let go of the item it was writing, leaving what
  /// becomes of that item to the caller.
  void _releaseComposer() {
    _composingId = null;
    _composer.controller.clear();
    _composer.unacknowledged = null;
    _composer.typedSinceFocus = false;
    _refreshOrder();
  }

  // -------------------------------------------------------------------
  // Layout

  double _rowHeight(String id) =>
      _rowHeights[id] ??
      (id == _kHeaderId ? _estimatedHeaderHeight : _minimumRowHeight);

  void _measuredRow(String id, double height) {
    if (!mounted) return;
    // Only the header may be shorter than a row.
    final measured = id == _kHeaderId
        ? height
        : math.max(_minimumRowHeight, height);
    final previous = _rowHeights[id];
    if (previous != null && (previous - measured).abs() < 0.5) return;
    setState(() => _rowHeights[id] = measured);
  }

  ({Map<String, double> tops, double total}) _layout() {
    final tops = <String, double>{};
    var y = 0.0;
    for (final id in _uncheckedOrder) {
      tops[id] = y;
      y += _rowHeight(id);
    }
    if (!widget.readOnly) {
      tops[_kComposerId] = y;
      y += _rowHeight(_kComposerId);
    }
    if (_checked.isNotEmpty) {
      tops[_kHeaderId] = y;
      y += _rowHeight(_kHeaderId);
      if (_showChecked) {
        for (final item in _checked) {
          tops[item.id] = y;
          y += _rowHeight(item.id);
        }
      }
    }
    return (tops: tops, total: y);
  }

  _RowMetrics get _rowMetrics => _metrics ??= _measureRowMetrics(
    Theme.of(context).textTheme.bodyLarge ?? const TextStyle(),
  );

  _RowMetrics _measureRowMetrics(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'x', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final lineHeight = painter.preferredLineHeight;
    painter.dispose();
    // A generous text scale can make one line taller than the nominal row.
    final bandHeight = math.max(_minimumRowHeight, lineHeight);
    return _RowMetrics(
      bandHeight: bandHeight,
      textPadding: (bandHeight - lineHeight) / 2,
    );
  }

  /// How long a row's own controls take to settle: the affordances fading
  /// under the pointer or the caret, the row's highlight, the composer's "+"
  /// giving way to a checkbox. Short enough that none of it is ever something
  /// to wait for, but never an instant jump.
  Duration get _controlFade =>
      Motion.reduced(context) ? Duration.zero : Motion.fast;

  /// Centres a row control on the first text line (see [_RowMetrics]).
  Widget _firstLineBand(Widget child) => SizedBox(
    height: _rowMetrics.bandHeight,
    child: Center(widthFactor: 1, child: child),
  );

  // -------------------------------------------------------------------
  // The composer's "+" giving way to a checkbox

  /// Shaping for that swap, as a fraction of [_swapDuration]. Neither control
  /// travels: they trade the same slot, so there is nothing to cross paths
  /// with. The "+" contracts to a point and accelerates away; the checkbox
  /// grows into the space it leaves, arriving with the same small overshoot
  /// every other checkbox in the app pops with, so it reads as a checkbox
  /// appearing rather than an icon being substituted.
  ///
  /// The windows overlap by a quarter, which is enough that the slot is never
  /// empty but not so much that the two are both solid at once.
  static const Curve _swapOut = Interval(0, 0.55, curve: Curves.easeIn);
  static const Curve _swapIn = Interval(0.3, 1, curve: Curves.easeOut);
  static const Curve _swapInScale = Interval(0.3, 1, curve: Curves.easeOutBack);

  /// Longer than [_controlFade] because the two halves run in sequence rather
  /// than together; each still gets well under a tenth of a second.
  Duration get _swapDuration =>
      Motion.reduced(context) ? Duration.zero : Motion.base;

  Widget _composerLeading(ChecklistItem? composing, ColorScheme scheme) {
    return SizedBox.square(
      // A fixed slot, so the swap can't nudge the text field beside it. It is
      // exactly a checkbox wide: the "+" stands in for the checkbox this row
      // is about to have, so the two must sit where every row above has one.
      key: const Key('checklist-composer-leading'),
      dimension: PopCheckbox.sizeOf(context),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: composing == null ? 0.0 : 1.0),
        duration: _swapDuration,
        builder: (context, t, _) {
          final leaving = 1 - _swapOut.transform(t);
          final arriving = _swapIn.transform(t);
          return Stack(
            // Unclipped so the checkbox's celebration dots can leave the slot.
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            // Keyed, or the survivor would be matched to the departed one's
            // element when the list shortens back to one child, rebuilding the
            // checkbox from scratch — and dropping its pop — as the "+" goes.
            children: [
              if (leaving > 0)
                Opacity(
                  key: const ValueKey('checklist-composer-add'),
                  opacity: leaving,
                  child: Transform.scale(
                    scale: 0.7 + 0.3 * leaving,
                    child: Icon(
                      Icons.add,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // Present from the keystroke, not from the moment it starts to
              // show: the item exists as soon as there is text, so the slot
              // has to be tickable for the whole swap, not just the tail.
              if (composing != null || arriving > 0)
                Opacity(
                  key: const ValueKey('checklist-composer-checkbox'),
                  opacity: arriving,
                  child: Transform.scale(
                    scale: 0.6 + 0.4 * _swapInScale.transform(t),
                    child: PopCheckbox(
                      value: false,
                      // Ticking what is being written finishes it: the row is
                      // handed to the list, then checked off it.
                      onChanged: (_) {
                        final item = composing;
                        _commitComposing();
                        _handleToggle(item);
                      },
                      sideColor: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------
  // Drag to reorder (handle-initiated, unchecked rows only)

  void _dragStart(String id, double startTop) {
    setState(() {
      _draggingId = id;
      _dragY = startTop;
    });
  }

  void _dragUpdate(double dy) {
    final draggingId = _draggingId;
    if (draggingId == null) return;
    final maxY =
        _uncheckedOrder.fold<double>(0, (acc, id) => acc + _rowHeight(id)) -
        _rowHeight(draggingId);
    _dragY = (_dragY + dy).clamp(0.0, maxY < 0 ? 0.0 : maxY);

    // Find the insertion index for the dragged row's center.
    final center = _dragY + _rowHeight(draggingId) / 2;
    var acc = 0.0;
    var index = 0;
    for (final id in _uncheckedOrder) {
      if (id == draggingId) continue;
      if (center > acc + _rowHeight(id) / 2) {
        index++;
        acc += _rowHeight(id);
      } else {
        break;
      }
    }
    final from = _uncheckedOrder.indexOf(draggingId);
    setState(() {
      if (from != index) {
        _uncheckedOrder.removeAt(from);
        _uncheckedOrder.insert(index, draggingId);
      }
    });
  }

  void _dragEnd() {
    if (_draggingId == null) return;
    setState(() => _draggingId = null);
    // The row being written is not in [_uncheckedOrder], but it is still part
    // of the list and must not be dropped from it.
    final composing = _composingId == null ? null : _byId[_composingId];
    final reordered = [
      for (final id in _uncheckedOrder)
        if (_byId[id] case final ChecklistItem item) item,
      ?composing,
      ..._checked,
    ];
    final current = [for (final item in widget.items) item.id];
    final proposed = [for (final item in reordered) item.id];
    if (current.join('|') != proposed.join('|')) {
      widget.onReorderItems(reordered);
    }
  }

  // -------------------------------------------------------------------
  // Suggestions popup

  /// Items already on the list, which a suggestion would only duplicate.
  /// Only items still *active* (unchecked) count: a checked-off item is done,
  /// so offering it back is exactly what you want, re-adding last week's
  /// groceries is the whole point of the history.
  Set<String> _activeTexts({String? except}) => {
    for (final item in widget.items)
      if (!item.done && item.id != except && item.text.trim().isNotEmpty)
        item.text,
  };

  ({String rowId, LayerLink link, List<String> suggestions})? _popupTarget() {
    if (widget.readOnly) return null;
    if (_composer.focusNode.hasFocus) {
      final suggestions = widget.suggestionsFor(
        _composer.text,
        _activeTexts(except: _composingId),
      );
      if (suggestions.isEmpty) return null;
      return (
        rowId: _kComposerId,
        link: _composer.link,
        suggestions: suggestions,
      );
    }
    for (final entry in _handles.entries) {
      final handles = entry.value;
      if (handles.focusNode.hasFocus &&
          handles.typedSinceFocus &&
          handles.text.trim().isNotEmpty) {
        final suggestions = widget.suggestionsFor(
          handles.text,
          _activeTexts(except: entry.key),
        );
        if (suggestions.isEmpty) return null;
        return (rowId: entry.key, link: handles.link, suggestions: suggestions);
      }
    }
    return null;
  }

  void _applySuggestion(String rowId, String text) {
    // Picking something the list already has checked off unchecks it, rather
    // than adding a second copy of it.
    final checkedTwin = widget.items
        .where((item) => item.done && item.text == text)
        .firstOrNull;
    if (rowId == _kComposerId) {
      final composingId = _composingId;
      if (checkedTwin != null) {
        _discardComposing();
        widget.onToggle(checkedTwin.id);
      } else if (composingId != null) {
        _composer.controller.text = text;
        _composer.unacknowledged = text;
        widget.onItemTextChanged(composingId, text);
        _commitComposing();
      } else {
        widget.onAdd(text);
      }
      _composer.focusNode.requestFocus();
      setState(() {});
      return;
    }
    final handles = _handles[rowId];
    if (checkedTwin != null) {
      widget.onToggle(checkedTwin.id);
      // The row the user was typing in keeps what it had before.
      final original = _byId[rowId]?.text ?? '';
      if (handles != null) {
        handles.controller.text = original;
        handles.controller.selection = TextSelection.collapsed(
          offset: original.length,
        );
        handles.typedSinceFocus = false;
        handles.unacknowledged = null;
        // Restoring an empty row leaves it empty: keep backspace working.
        _armEmptyMarker(handles);
      }
      setState(() {});
      return;
    }
    if (handles != null) {
      handles.controller.text = text;
      handles.controller.selection = TextSelection.collapsed(
        offset: text.length,
      );
      handles.typedSinceFocus = false;
      handles.unacknowledged = text;
    }
    widget.onItemTextChanged(rowId, text);
    setState(() {});
  }

  Widget _buildPopup(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _popupRevision,
    builder: (context, _, _) {
      final target = _popupTarget();
      if (target == null) return const SizedBox.shrink();
      return ChecklistSuggestions(
        link: target.link,
        suggestions: target.suggestions,
        query: target.rowId == _kComposerId
            ? _composer.text.trim()
            : (_handles[target.rowId]?.text.trim() ?? ''),
        scrollController: _suggestionsScroll,
        onPick: (suggestion) => _applySuggestion(target.rowId, suggestion),
      );
    },
  );

  // -------------------------------------------------------------------
  // Rows

  /// The text field every row is built around. The composer's is the same
  /// widget in the same place, so materializing an item under it never
  /// re-creates the field the user is typing into.
  Widget _rowField({
    required _RowHandles handles,
    required TextStyle style,
    String? hintText,
    TextCapitalization textCapitalization = TextCapitalization.none,
    required ValueChanged<String> onChanged,
    required VoidCallback onSubmitted,
    Widget? below,
  }) {
    final field = CompositedTransformTarget(
      link: handles.link,
      child: TextField(
        controller: handles.controller,
        focusNode: handles.focusNode,
        readOnly: widget.readOnly,
        enabled: !widget.readOnly,
        minLines: 1,
        maxLines: null,
        textInputAction: TextInputAction.next,
        textCapitalization: textCapitalization,
        inputFormatters: [_stripMarker],
        style: style,
        decoration: InputDecoration(
          hintText: hintText,
          border: InputBorder.none,
          isDense: true,
          // The row's own text padding positions the first line, so the
          // decorator must not also shift it: on desktop the ambient
          // density is compact, and InputDecorator spends half of that
          // adjustment off the top padding, lifting the text ~4px clear of
          // the controls beside it.
          visualDensity: VisualDensity.standard,
          contentPadding: EdgeInsets.symmetric(
            vertical: _rowMetrics.textPadding,
          ),
        ),
        onChanged: onChanged,
        // TextField's default "next" completion asks the focus scope for a
        // widget that does not exist until the insert rebuild. Keep the
        // current text-input connection alive; onSubmitted performs the
        // deliberate handoff instead.
        onEditingComplete: () {},
        onSubmitted: (_) => onSubmitted(),
      ),
    );
    if (below == null) return Expanded(child: field);
    // The chip hangs under the text rather than beside it: a row is already
    // five controls wide on a phone, and row heights are measured, so growing
    // one costs nothing but the space it takes.
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          field,
          Padding(padding: const EdgeInsets.only(bottom: 8), child: below),
        ],
      ),
    );
  }

  Widget _itemRow(ChecklistItem item, {required bool dragging}) {
    final handles = _handleFor(item);
    final scheme = Theme.of(context).colorScheme;
    final textStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
          decoration: item.done ? TextDecoration.lineThrough : null,
          color: item.done ? scheme.onSurfaceVariant : null,
        );
    final query = widget.highlightQuery.trim().toLowerCase();
    final matches = query.isNotEmpty && item.text.toLowerCase().contains(query);
    final reminder = widget.reminders[item.id];
    // A checked row cannot carry a reminder, so it is not offered one either:
    // the rule is the server's, and the UI should not invite a 400.
    final canRemind =
        widget.onSetReminder != null && !widget.readOnly && !item.done;
    // Touch has no hover: keep affordances visible. Desktop reveals them on
    // hover/focus, keeping the list visually calm.
    bool showsControls(bool hovered, bool focused) =>
        !widget.readOnly &&
        (isTouchPrimaryPlatform || hovered || focused || dragging);

    // Hover changes twice per row the pointer crosses, and the caret moves
    // just as often. Routing both through notifiers keeps either from
    // rebuilding every row in the list, only these three wrappers rebuild,
    // and the subtrees they wrap (the drag gesture, the remove button, the
    // field) are passed straight through.
    Widget onRowState(
      Widget child,
      Widget Function(bool hovered, bool focused, Widget child) build,
    ) => ListenableBuilder(
      listenable: Listenable.merge([_hovered, _focusedId]),
      child: child,
      builder: (context, child) =>
          build(_hovered.value == item.id, _focusedId.value == item.id, child!),
    );

    final row = MouseRegion(
      onEnter: (_) => _hovered.value = item.id,
      onExit: (_) {
        if (_hovered.value == item.id) _hovered.value = null;
      },
      child: onRowState(
        // Every row keeps the exact same height and widget shape whether
        // hovered or not: controls fade in with Opacity instead of being
        // added to the tree, so hovering never shifts the layout.
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _minimumRowHeight),
          child: Row(
            // Every control belongs to the first text line: each one is
            // centred in a band of that line's height (see [_RowMetrics]), so
            // a multiline field grows downward without pulling its checkbox
            // into the vertical centre of the whole item.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              onRowState(
                MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) {
                      final layout = _layout();
                      _dragStart(item.id, layout.tops[item.id] ?? 0);
                    },
                    onVerticalDragUpdate: (details) =>
                        _dragUpdate(details.delta.dy),
                    onVerticalDragEnd: (_) => _dragEnd(),
                    onVerticalDragCancel: _dragEnd,
                    child: SizedBox(
                      width: 24,
                      height: _rowMetrics.bandHeight,
                      child: Icon(
                        Icons.drag_indicator,
                        size: 20,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
                (hovered, focused, child) => AnimatedOpacity(
                  opacity: !item.done && showsControls(hovered, focused)
                      ? 1
                      : 0,
                  duration: _controlFade,
                  curve: Motion.standard,
                  child: IgnorePointer(
                    ignoring: item.done || widget.readOnly,
                    child: child,
                  ),
                ),
              ),
              _firstLineBand(
                PopCheckbox(
                  value: item.done,
                  onChanged: widget.readOnly
                      ? null
                      : (_) => _handleToggle(item),
                  sideColor: scheme.onSurfaceVariant,
                ),
              ),
              _rowField(
                handles: handles,
                style: textStyle,
                below: reminder == null
                    ? null
                    : ReminderChip(
                        at: reminder.at,
                        repeat: reminder.repeat,
                        // The chip is the row's "edit this reminder": having
                        // set one, that is what the bell beside it would do
                        // anyway, and the chip is the bigger target.
                        onTap: canRemind
                            ? () => widget.onSetReminder!(item.id)
                            : null,
                      ),
                onChanged: (value) => _itemTextChanged(item, handles, value),
                onSubmitted: () {
                  // Enter continues the list: a new row right below this one.
                  // Give the keyboard an already-mounted target inside the
                  // submit callback, before creating the row that will
                  // ultimately own the caret.
                  _composer.focusNode.requestFocus();
                  if (widget.onInsertAfter != null && !item.done) {
                    _pendingFocusId = widget.onInsertAfter!(item.id);
                    setState(() {});
                  }
                },
              ),
              if (canRemind)
                onRowState(
                  _firstLineBand(
                    IconButton(
                      icon: Icon(
                        reminder == null ? Icons.alarm_add : Icons.alarm_on,
                        size: 18,
                      ),
                      color: reminder == null
                          ? scheme.onSurfaceVariant
                          : scheme.primary,
                      tooltip: reminder == null
                          ? 'Remind me about this item'
                          : 'Edit reminder',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      onPressed: () => widget.onSetReminder!(item.id),
                    ),
                  ),
                  (hovered, focused, child) {
                    // A row that already carries one keeps its bell lit: the
                    // state has to be visible without hunting for it, the way
                    // the chip below the text is.
                    final show =
                        reminder != null || showsControls(hovered, focused);
                    return AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: _controlFade,
                      curve: Motion.standard,
                      child: IgnorePointer(ignoring: !show, child: child),
                    );
                  },
                ),
              onRowState(
                _firstLineBand(
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Remove item',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    onPressed: () => widget.onRemove(item.id),
                  ),
                ),
                (hovered, focused, child) {
                  final show = showsControls(hovered, focused);
                  return AnimatedOpacity(
                    opacity: show ? 1 : 0,
                    duration: _controlFade,
                    curve: Motion.standard,
                    child: IgnorePointer(ignoring: !show, child: child),
                  );
                },
              ),
            ],
          ),
        ),
        // Animated, so the pointer crossing a row washes its highlight in and
        // out rather than flicking it, and picking a row up fades its lift in
        // under the finger.
        (hovered, focused, child) => AnimatedContainer(
          key: ValueKey('checklist-row-background-${item.id}'),
          duration: _controlFade,
          curve: Motion.standard,
          decoration: BoxDecoration(
            color: dragging
                ? scheme.surfaceContainerHigh
                : matches
                ? scheme.tertiaryContainer.withValues(alpha: 0.55)
                : focused && !widget.readOnly
                ? scheme.primary.withValues(alpha: 0.035)
                : hovered && !widget.readOnly
                ? scheme.onSurface.withValues(alpha: 0.04)
                : null,
            borderRadius: BorderRadius.circular(kRadius),
            boxShadow: [
              if (dragging)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          child: child,
        ),
      ),
    );
    return RepaintBoundary(child: row);
  }

  /// A row, reusing the last one built for this item when nothing about it has
  /// changed (see [_rows]).
  Widget _rowFor(ChecklistItem item, {required bool dragging}) {
    // The dragged row is the one thing a drag step does change, and there is
    // only ever one of it, so it stays out of the cache entirely.
    if (dragging) {
      _rows.remove(item.id);
      _rowItems.remove(item.id);
      return _itemRow(item, dragging: true);
    }
    final cached = _rows[item.id];
    if (cached != null && _rowItems[item.id] == item) return cached;
    final built = _itemRow(item, dragging: false);
    _rows[item.id] = built;
    _rowItems[item.id] = item;
    return built;
  }

  /// The row at the end of the list, where new items are written. Once the
  /// first keystroke has given it an item it looks (and ticks) like any other
  /// row; before that it is the "+ List item" invitation.
  Widget _composerRow() {
    final scheme = Theme.of(context).colorScheme;
    final textStyle =
        Theme.of(context).textTheme.bodyLarge ?? const TextStyle();
    final composing = _composingId == null ? null : _byId[_composingId];
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _minimumRowHeight),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Aligned with the drag-handle column above.
          const SizedBox(width: 24),
          // The first keystroke turns the invitation into a real row, and its
          // "+" gives way to a checkbox in place: see [_swapProgress].
          _firstLineBand(_composerLeading(composing, scheme)),
          _rowField(
            handles: _composer,
            style: textStyle,
            hintText: 'List item',
            textCapitalization: TextCapitalization.sentences,
            onChanged: _composerChanged,
            // Enter starts the next item, leaving this one on the list.
            onSubmitted: _commitComposing,
          ),
          ValueListenableBuilder<String?>(
            valueListenable: _focusedId,
            builder: (context, focusedId, _) {
              final show = focusedId == _kComposerId;
              return AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: _controlFade,
                curve: Motion.standard,
                child: IgnorePointer(
                  ignoring: !show,
                  // An empty composer has no item to remove yet, so its
                  // button gives the same clear exit as a row's: relinquish
                  // focus so the soft keyboard closes.
                  child: _firstLineBand(
                    IconButton(
                      key: const Key('checklist-new-row-close'),
                      icon: const Icon(Icons.close, size: 18),
                      color: scheme.onSurfaceVariant,
                      tooltip: composing == null
                          ? 'Close keyboard'
                          : 'Remove item',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      onPressed: composing == null
                          ? _composer.focusNode.unfocus
                          : _discardComposing,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Folds the checked section away, or brings it back. Unfolding puts rows on
  /// screen that were not in the tree at all, so they get the same short glide
  /// a newly added row gets rather than blinking into place under the header.
  void _toggleChecked() {
    setState(() {
      _showChecked = !_showChecked;
      if (_showChecked) {
        _enteringIds.addAll(_checked.map((item) => item.id));
      }
    });
  }

  Widget _checkedHeader(int count) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _toggleChecked,
      borderRadius: BorderRadius.circular(kRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _showChecked ? 0.25 : 0,
              duration: _controlFade,
              curve: Motion.standard,
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count checked ${count == 1 ? 'item' : 'items'}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // Ticking

  /// Ticks a row, and celebrates the tick that empties the list.
  ///
  /// Fired from the tap rather than from a diff of [AnimatedChecklist.items]:
  /// the edit is optimistic and comes back through the parent a frame or two
  /// later, and a diff would also fire for a list that merely arrives complete
  /// (a sync from another device, or opening a finished note).
  void _handleToggle(ChecklistItem? item) {
    if (item == null) return;
    if (_completesList(item) && !Motion.reduced(context)) {
      setState(() {
        _celebration++;
        _celebrating = true;
      });
      HapticFeedback.lightImpact();
    }
    widget.onToggle(item.id);
  }

  /// Whether ticking [item] would leave nothing on the list unchecked.
  /// Unticking one never does, however few are left.
  bool _completesList(ChecklistItem item) {
    if (item.done) return false;
    for (final other in widget.items) {
      if (!other.done && other.id != item.id) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleFocusHandoff();
    final layout = _layout();
    final snap = _snapFrame;
    if (snap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _snapFrame = false);
      });
    }
    // A row's glide to its new position, unless this is a frame that has to
    // land outright (see [_snapFrame]) or motion is turned down.
    final moveDuration = snap || Motion.reduced(context)
        ? Duration.zero
        : Motion.base;
    Widget positioned(String id, Widget child) {
      final dragging = id == _draggingId;
      Widget positionedChild = MeasureSize(
        onChange: (size) => _measuredRow(id, size.height),
        child: child,
      );
      if (_enteringIds.contains(id)) {
        positionedChild = _ChecklistRowEntrance(
          key: ValueKey('checklist-entrance-$id'),
          child: positionedChild,
        );
      }
      // One widget shape for dragged and resting rows: swapping widget types
      // mid-gesture would rebuild the row's element tree and cancel the very
      // drag recognizer driving it. The dragged row just animates with
      // Duration.zero so it tracks the pointer exactly.
      return AnimatedPositioned(
        key: ValueKey(id),
        duration: dragging ? Duration.zero : moveDuration,
        curve: Motion.standard,
        left: 0,
        right: 0,
        top: dragging ? _dragY : (layout.tops[id] ?? 0),
        child: positionedChild,
      );
    }

    return OverlayPortal(
      controller: _popup,
      overlayChildBuilder: _buildPopup,
      child: SizedBox(
        height: layout.total,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final id in _uncheckedOrder)
              if (_byId[id] case final ChecklistItem item)
                positioned(id, _rowFor(item, dragging: id == _draggingId)),
            if (!widget.readOnly) positioned(_kComposerId, _composerRow()),
            if (_checked.isNotEmpty)
              positioned(_kHeaderId, _checkedHeader(_checked.length)),
            if (_checked.isNotEmpty && _showChecked)
              for (final item in _checked)
                positioned(item.id, _rowFor(item, dragging: false)),
            // Last, so the confetti fly over the rows rather than under them.
            if (_celebrating)
              Positioned.fill(
                child: AllDoneBurst(
                  key: ValueKey('checklist-all-done-$_celebration'),
                  onDone: () {
                    if (mounted) setState(() => _celebrating = false);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Gives a newly-created checklist item a short horizontal glide and fade.
/// Existing rows only move through [AnimatedPositioned], so opening a note
/// never makes the whole list replay its entrance.
class _ChecklistRowEntrance extends StatelessWidget {
  final Widget child;

  const _ChecklistRowEntrance({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.reduced(context) ? Duration.zero : Motion.base,
      curve: Motion.emphasized,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(20 * (1 - value), 0),
          child: child,
        ),
      ),
    );
  }
}
