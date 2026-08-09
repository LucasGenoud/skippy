import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:animations/animations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/editor_history.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/home_widgets.dart';
import '../util/label_style.dart';
import '../util/linkify.dart';
import '../util/location_geofences.dart';
import '../util/mime.dart';
import '../util/motion.dart';
import '../util/note_export.dart';
import '../util/note_routes.dart';
import '../util/snack.dart';
import '../util/widget_payload.dart';
import 'history_screen.dart';
import '../widgets/checklist/animated_checklist.dart';
import '../widgets/audio_player.dart';
import '../widgets/board/move_to_stage_sheet.dart';
import '../widgets/color_picker.dart';
import '../widgets/editor/attachment_tiles.dart';
import '../widgets/editor/editor_bottom_bar.dart';
import '../widgets/editor/highlighted_text_field.dart';
import '../widgets/editor/note_actions_button.dart';
import '../widgets/file_drop.dart';
import '../widgets/labels_sheet.dart';
import '../widgets/link_preview.dart';
import '../widgets/markdown_toolbar.dart';
import '../widgets/paste_files.dart';
import '../widgets/pick_image.dart';
import '../widgets/reminder_picker.dart';
import '../widgets/screen_width.dart';
import '../widgets/share_dialog.dart';
import '../widgets/workspace_menu.dart';
import '../widgets/transcribing_indicator.dart';

/// Full-screen note editor. Everything autosaves as you type (the store
/// debounces the network write); empty notes are discarded on close, exactly
/// on wide layouts.
///
/// With [noteId] null this is the "new note" editor: the note is only created
/// in the store on the first actual change, so backing out of an untouched
/// editor never produces a phantom note.
///
/// The editor keeps a session history of the note's content, undo/redo
/// buttons in the bottom bar (typing bursts group into single steps; checks,
/// adds, removes, reorders and conversions are each their own step).
class EditorScreen extends StatefulWidget {
  final String? noteId;
  final NoteKind kind;

  /// Presented as a centered dialog (wide/desktop layouts) rather than a
  /// fullscreen route: the body shrinks to its content and the back arrow
  /// becomes a close button. Use [openNoteEditor] instead of setting this
  /// directly.
  final bool modal;

  /// Labels a new note starts with, the view it was composed in (a label
  /// filter) files it automatically. Ignored when [noteId] is given.
  final Set<String> labelIds;

  /// Board column a note composed from that column starts in.
  final String? stageId;

  /// Whether this editor was opened from the board. Column placement is a
  /// board-specific control, so it stays out of the ordinary note editor.
  final bool openedFromBoard;

  /// Opens a checklist with its empty "add item" row focused and the keyboard
  /// up, ready to type. For the home-screen widget's Add item row: a widget
  /// takes no text input on either platform, so the item is written here.
  final bool addChecklistItem;

  const EditorScreen({
    super.key,
    this.noteId,
    this.kind = NoteKind.text,
    this.modal = false,
    this.labelIds = const {},
    this.stageId,
    this.openedFromBoard = false,
    this.addChecklistItem = false,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

/// Whether this layout opens notes as a centered modal
/// instead of fullscreen. Same breakpoint as the quick-add bar.
///
/// Reads the width alone: [MediaQuery.sizeOf] is one aspect covering both axes,
/// so asking it would rebuild the whole editor on every frame of the Android
/// keyboard's slide (the activity is `adjustResize`, so the view really does
/// shrink). See [ScreenWidth].
bool wantsModalEditor(BuildContext context) =>
    ScreenWidth.isAtLeast(context, 600);

/// Width the wide-layout modal grows to. [_EditorMorph] needs it up front to
/// know how far the opening surface has to scale.
const double _modalMaxWidth = 600;

/// Only a gesture that begins within this left-hand edge can dismiss the
/// fullscreen editor. Keeping the recognizer out of the arena elsewhere
/// preserves horizontal interactions inside the note.
const double _edgeDismissWidth = 24;
const double _edgeDismissDistance = 72;
const double _edgeDismissFlingVelocity = 700;

/// Global-coordinate bounds of the widget that [context] belongs to, the box a
/// container morph should grow out of. Pass the result to [openNoteEditor] as
/// `sourceRect`; null (no render box yet, or none at all) simply falls back to
/// the plain fade-scale entrance.
Rect? morphSourceRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Open the editor for the current layout: a centered modal over a dimmed
/// barrier on wide screens, or the given fullscreen container-transform
/// ([openFullscreen], from an enclosing OpenContainer) on narrow ones.
/// Dismissing the modal, barrier tap, Escape, or the close button,
/// finalizes the note exactly like popping the fullscreen editor.
///
/// With [sourceRect] the modal morphs out of that box and shrinks back into it
/// on close, so a card on a desktop grid expands into the editor the same way
/// it does on a phone (see [morphSourceRect]); without one it fades in from
/// the middle of the screen.
Future<void> openNoteEditor(
  BuildContext context, {
  required VoidCallback openFullscreen,
  String? noteId,
  NoteKind kind = NoteKind.text,
  Set<String> labelIds = const {},
  String? stageId,
  bool openedFromBoard = false,
  Rect? sourceRect,
}) {
  // Drop focus from whatever field held it (search bar, quick-add, chat
  // composer). Without this the enclosing FocusScope remembers that field
  // and hands focus straight back when the editor pops, resummoning the
  // soft keyboard right as the note closes.
  FocusManager.instance.primaryFocus?.unfocus();
  if (!wantsModalEditor(context)) {
    openFullscreen();
    return Future<void>.value();
  }
  return showGeneralDialog<void>(
    context: context,
    // Named so a widget or notification tap can tell this note is already
    // open and raise it instead of stacking a second editor over it.
    routeSettings: noteId == null
        ? null
        : RouteSettings(name: noteRouteName(noteId)),
    barrierDismissible: true,
    barrierLabel: 'Close note',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: Motion.slow,
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        sourceRect == null || Motion.reduced(context)
        ? FadeScaleTransition(animation: animation, child: child)
        : _EditorMorph(animation: animation, source: sourceRect, child: child),
    pageBuilder: (context, animation, secondaryAnimation) => Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _modalMaxWidth,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadius),
          child: EditorScreen(
            noteId: noteId,
            kind: kind,
            modal: true,
            labelIds: labelIds,
            stageId: stageId,
            openedFromBoard: openedFromBoard,
          ),
        ),
      ),
    ),
  );
}

/// The desktop half of the card→editor container transform: the modal grows out
/// of the card (or button) that opened it and shrinks back into it on close,
/// mirroring the fullscreen [OpenContainer] morph phones get.
///
/// It scales and slides the finished dialog rather than tweening its box,
/// because the modal hugs its content, its final height isn't known when the
/// route starts, and re-laying the editor out on every frame of a 250ms
/// transition is exactly the kind of work that makes a morph stutter. The
/// surface reaches full opacity early on, so the growing note reads as one
/// opaque object leaving the grid instead of a fade.
class _EditorMorph extends StatelessWidget {
  final Animation<double> animation;

  /// Global bounds of the widget the editor is growing out of.
  final Rect source;

  final Widget child;

  const _EditorMorph({
    required this.animation,
    required this.source,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    // The dialog is centred in the route and as wide as its constraints allow,
    // so both ends of the flight are known without measuring anything.
    final center = screen.center(Offset.zero);
    final width = math.min(_modalMaxWidth, screen.width);

    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        // Emphasized on the way out of the card, calmer on the way back in.
        final curve = animation.status == AnimationStatus.reverse
            ? Motion.standard
            : Motion.emphasized;
        final t = curve.transform(animation.value.clamp(0.0, 1.0));
        final scale = lerpDouble(source.width / width, 1.0, t)!;
        final origin = Offset.lerp(source.center, center, t)!;
        return Transform.translate(
          offset: origin - center,
          // Alignment.center is the child's centre, which is the dialog's
          // centre too, so the surface swells around its own middle.
          child: Transform.scale(
            scale: scale,
            child: Opacity(opacity: (t * 4).clamp(0.0, 1.0), child: child),
          ),
        );
      },
    );
  }
}

class _EditorScreenState extends State<EditorScreen> {
  static const _uuid = Uuid();

  late final NotesStore _store;
  late final SettingsStore _settings;
  late final TextEditingController _titleController;
  late final LinkifyingController _contentController;
  final _findController = TextEditingController();
  final _titleFocus = FocusNode();
  final _contentFocus = FocusNode();
  final _findFocus = FocusNode();

  String? _noteId;
  bool _closing = false;
  bool _finding = false;
  bool _uploading = false;
  // Files currently mid-upload, shown as dimmed placeholder tiles right where
  // their real attachment tile will appear once the network call resolves.
  final List<DroppedFile> _pendingUploads = [];
  bool _previewMarkdown = false;
  bool _reminderPickerOpen = false;
  double _edgeSwipeDistance = 0;
  bool _edgeSwipeDismissed = false;

  // Undo/redo session history (see EditorHistory for the grouping rules).
  late final EditorHistory _history;
  bool _restoring = false;

  Note? get _note => _noteId == null ? null : _store.noteById(_noteId!);

  @override
  void initState() {
    super.initState();
    _store = context.read<NotesStore>();
    _settings = context.read<SettingsStore>();
    _noteId = widget.noteId;
    final note = _note;
    // Existing markdown notes open in their rendered form. A new markdown
    // draft still opens as source so typing can begin immediately.
    _previewMarkdown = note?.kind == NoteKind.markdown;
    _titleController = TextEditingController(text: note?.title ?? '');
    _contentController = LinkifyingController(text: note?.content ?? '');
    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    _findController.addListener(() => setState(() {}));
    _history = EditorHistory(_currentSnapshot());
    // A brand-new text/markdown note wants the body focused for immediate
    // typing. But focusing on mount makes iOS raise the keyboard while the open
    // transition (container morph / fade-scale modal) is still animating,
    // the two animations fight and the layout resizes mid-open, which stutters.
    // Wait for the route to finish opening, then focus.
    if (widget.noteId == null && widget.kind != NoteKind.checklist) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusBodyAfterOpen(),
      );
    }
  }

  void _focusBodyAfterOpen() {
    if (!mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _contentFocus.requestFocus();
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeStatusListener(onStatus);
      if (mounted && status == AnimationStatus.completed) {
        _contentFocus.requestFocus();
      }
    }

    animation.addStatusListener(onStatus);
  }

  @override
  void dispose() {
    _finalize();
    _titleController.dispose();
    _contentController.dispose();
    _findController.dispose();
    _titleFocus.dispose();
    _contentFocus.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Lifecycle

  NoteKind get _kind => _note?.kind ?? widget.kind;

  void _ensureNote() {
    if (_noteId != null) return;
    _noteId = _store
        .createDraft(
          kind: widget.kind,
          labelIds: widget.labelIds,
          stageId: widget.stageId,
        )
        .id;
  }

  void _finalize() {
    if (_closing) return;
    _closing = true;
    if (_noteId == null) {
      return;
    }
    final note = _note;
    if (note != null && note.isChecklist) {
      // Drop rows that are just whitespace before the final save.
      final pruned = [
        for (final item in note.items)
          if (item.text.trim().isNotEmpty) item,
      ];
      if (pruned.length != note.items.length) {
        _store.updateNoteContent(_noteId!, items: pruned);
      }
    }
    _store.finalizeNote(
      _noteId!,
      retainEmpty: _settings.locationReminderForNote(_noteId) != null,
    );
  }

  void _onTextChanged() {
    if (_restoring) return;
    final title = _titleController.text;
    final content = _contentController.text;
    if (_noteId == null) {
      if (title.trim().isEmpty && content.trim().isEmpty) return;
      _ensureNote();
    }
    _store.updateNoteContent(
      _noteId!,
      title: title,
      content: _kind != NoteKind.checklist ? content : null,
      // Typing must never rebuild the whole grid behind the editor on every
      // keystroke; the store throttles the notification instead.
      urgent: false,
    );
    _afterChange();
    setState(() {});
  }

  // -------------------------------------------------------------------
  // Undo / redo

  EditorSnapshot _currentSnapshot() {
    final note = _note;
    if (note != null) {
      return EditorSnapshot(
        kind: note.kind,
        title: note.title,
        content: note.content,
        items: List<ChecklistItem>.from(note.items),
      );
    }
    return EditorSnapshot(
      kind: widget.kind,
      title: _titleController.text,
      content: _contentController.text,
      items: const [],
    );
  }

  /// Record history after a mutation. Typing groups into bursts; [discrete]
  /// ops (check, add, remove, reorder, convert) always start a new step.
  void _afterChange({bool discrete = false}) {
    if (_restoring) return;
    _history.record(_currentSnapshot(), discrete: discrete);
  }

  void _undo() {
    final snapshot = _history.undo(_currentSnapshot());
    if (snapshot != null) _applySnapshot(snapshot);
  }

  void _redo() {
    final snapshot = _history.redo(_currentSnapshot());
    if (snapshot != null) _applySnapshot(snapshot);
  }

  void _applySnapshot(EditorSnapshot snapshot) {
    _restoring = true;
    FocusManager.instance.primaryFocus?.unfocus();
    _titleController.text = snapshot.title;
    _contentController.text = snapshot.content;
    final hasContent =
        snapshot.title.trim().isNotEmpty ||
        snapshot.content.trim().isNotEmpty ||
        snapshot.items.any((i) => i.text.trim().isNotEmpty);
    if (_noteId == null && hasContent) _ensureNote();
    if (_noteId != null) {
      _store.updateNoteContent(
        _noteId!,
        kind: snapshot.kind,
        title: snapshot.title,
        content: snapshot.content,
        items: snapshot.items,
      );
    }
    _history.resetTo(snapshot);
    _restoring = false;
    setState(() {});
  }

  // -------------------------------------------------------------------
  // Checklist editing

  List<ChecklistItem> get _items => _note?.items ?? const [];

  void _setItems(List<ChecklistItem> items, {bool discrete = true}) {
    _ensureNote();
    // Discrete ops (check, add, remove, reorder) show on the grid instantly;
    // row typing rides the same keystroke throttle as the text fields.
    _store.updateNoteContent(_noteId!, items: items, urgent: discrete);
    _afterChange(discrete: discrete);
    // Row typing doesn't rebuild the editor: the row's own controller already
    // shows the character, and rebuilding here means rebuilding every other
    // row (each a TextField) plus the attachments and bottom bar on every
    // keystroke, the thing that makes a long checklist feel laggy. The
    // store's throttled notify refreshes us within 200ms instead.
    if (discrete) setState(() {});
  }

  String _addItem(String text) {
    final item = ChecklistItem(id: _uuid.v4(), text: text.trim());
    _setItems([..._items, item]);
    return item.id;
  }

  void _updateItemText(String itemId, String text) {
    _setItems([
      for (final item in _items)
        item.id == itemId ? item.copyWith(text: text) : item,
    ], discrete: false);
  }

  void _toggleItem(String itemId) {
    _ensureNote();
    _store.toggleChecklistItem(_noteId!, itemId);
    _afterChange(discrete: true);
    setState(() {});
  }

  void _removeItem(String itemId) {
    _setItems([..._items]..removeWhere((i) => i.id == itemId));
  }

  /// Enter in a row: continue the list with an empty row right below it.
  String _insertItemAfter(String afterId) {
    final items = [..._items];
    final index = items.indexWhere((i) => i.id == afterId);
    final item = ChecklistItem(id: _uuid.v4(), text: '');
    items.insert(index < 0 ? items.length : index + 1, item);
    _setItems(items);
    return item.id;
  }

  // -------------------------------------------------------------------
  // Actions

  void _togglePin() {
    _ensureNote();
    _store.togglePin(_noteId!);
    setState(() {});
  }

  void _setColor(String color) {
    _ensureNote();
    _store.setColor(_noteId!, color);
    setState(() {});
  }

  Future<void> _editLabels() async {
    _ensureNote();
    await LabelsSheet.show(context, _noteId!);
    if (mounted) setState(() {});
  }

  void _archiveAndClose() {
    final note = _note;
    if (note == null || _store.canAutoDiscard(note.id)) return;
    final id = note.id;
    final wasArchived = note.archived;
    _store.setArchived(id, !wasArchived);
    Navigator.of(context).pop();
    showAppSnack(
      wasArchived ? 'Note unarchived' : 'Note archived',
      icon: wasArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
      actionLabel: 'Undo',
      onAction: () => _store.setArchived(id, wasArchived),
    );
  }

  void _deleteAndClose() {
    final note = _note;
    if (note == null) {
      Navigator.of(context).pop();
      return;
    }
    final id = note.id;
    _store.moveToTrash(id);
    Navigator.of(context).pop();
    showAppSnack(
      'Note moved to Trash',
      icon: Icons.delete_outline,
      kind: SnackKind.danger,
      actionLabel: 'Undo',
      onAction: () => _store.restoreFromTrash(id),
    );
  }

  void _duplicateNote() {
    final note = _note;
    if (note == null || note.isEmpty) return;
    _store.duplicate(note.id);
  }

  Future<void> _copyNoteToClipboard() async {
    final note = _note;
    if (note == null || note.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: noteToPlainText(note).trimRight()),
    );
  }

  /// Put this note on the device home screen.
  ///
  /// Only Android can place a widget for the user (`requestPinAppWidget`);
  /// iOS gives apps no such API at all, so there the honest thing is to explain
  /// where the control lives rather than pretend to do it.
  Future<void> _addToHomeScreen() async {
    // A draft has no id to hand a widget, and an unsaved edit would leave the
    // widget showing yesterday's text. Both are fixed by materializing first.
    _ensureNote();
    final note = _note;
    if (note == null) return;
    _store.updateNoteContent(
      note.id,
      title: _titleController.text,
      content: _contentController.text,
    );

    final widgets = HomeWidgets();
    if (await widgets.canPin()) {
      // The launcher opens the widget's configuration screen next; this is the
      // note it should offer first.
      await widgets.setPreselectedNote(note.id);
      await widgets.requestPin();
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _AddToHomeScreenHelp(noteTitle: widgetDisplayTitle(note)),
    );
  }

  Future<void> _rewriteWithAi(NoteRewriteMode mode) async {
    final note = _note;
    if (note == null ||
        note.isEmpty ||
        note.isAudio ||
        _store.isRewritingNote(note.id)) {
      return;
    }
    // Put the currently visible controllers into the store before waiting for
    // the server-side rewrite; [NotesStore.rewriteNote] then flushes that
    // pending patch before it asks the LLM to transform the note.
    _store.updateNoteContent(
      note.id,
      title: _titleController.text,
      content: note.isChecklist ? null : _contentController.text,
      items: note.isChecklist ? _items : null,
    );
    try {
      await _store.rewriteNote(note.id, mode);
      if (!mounted) return;
      final updated = _note;
      if (updated != null) {
        _restoring = true;
        _titleController.text = updated.title;
        if (!updated.isChecklist) _contentController.text = updated.content;
        _restoring = false;
      }
      _afterChange(discrete: true);
      setState(() {});
      showAppSnack(
        mode == NoteRewriteMode.concise
            ? 'Note cleaned up'
            : 'Grammar corrected',
        icon: Icons.auto_fix_high_outlined,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnack(
        "Couldn't update the note with AI",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  void _convertKind(NoteKind target) {
    _ensureNote();
    // Flush any un-debounced content first so nothing is lost in conversion.
    _store.updateNoteContent(
      _noteId!,
      title: _titleController.text,
      content: _kind != NoteKind.checklist ? _contentController.text : null,
    );
    _store.convertKind(_noteId!, target);
    final note = _note;
    if (note != null && !note.isChecklist) {
      _restoring = true;
      _contentController.text = note.content;
      _restoring = false;
    }
    _previewMarkdown = false;
    _afterChange(discrete: true);
    setState(() {});
  }

  /// Shared upload path for the image picker, the paperclip, and drag-drop:
  /// enforces the size cap, drives the progress bar, and reports failures
  /// with [failureMessage].
  Future<void> _uploadAll(
    List<DroppedFile> files, {
    required String failureMessage,
  }) async {
    final accepted = [
      for (final f in files)
        if (f.bytes.length <= maxUploadBytes) f,
    ];
    if (accepted.length != files.length) {
      showAppSnack(
        'Files are limited to 25 MB',
        icon: Icons.error_outline,
        kind: SnackKind.warning,
      );
    }
    if (accepted.isEmpty) return;
    _ensureNote();
    final id = _noteId!;
    setState(() => _uploading = true);
    try {
      for (final f in accepted) {
        setState(() => _pendingUploads.add(f));
        try {
          await _store.uploadFile(id, f.bytes, f.mime, f.name);
        } finally {
          if (mounted) setState(() => _pendingUploads.remove(f));
        }
      }
    } catch (_) {
      showAppSnack(
        failureMessage,
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickImage() async {
    _ensureNote();
    try {
      final picked = await pickNoteImage(context);
      if (picked == null) return;
      await _uploadAll([picked], failureMessage: "Couldn't upload the image");
    } catch (_) {
      showAppSnack(
        "Couldn't upload the image",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  /// Attach any files (documents, archives, audio…). Images render inline;
  /// everything else becomes a download tile.
  Future<void> _pickFile() async {
    _ensureNote();
    try {
      await _uploadAll(
        await pickAnyFiles(),
        failureMessage: "Couldn't upload the file",
      );
    } catch (_) {
      showAppSnack(
        "Couldn't upload the file",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  /// Files dragged in from the OS attach to this note (web only).
  Future<void> _addDroppedFiles(List<DroppedFile> files) async {
    if (_note?.trashed ?? false) return;
    await _uploadAll(
      files,
      failureMessage: "Couldn't upload the dropped files",
    );
  }

  /// Files on the clipboard attach to this note: a pasted screenshot renders
  /// inline like any other image, a pasted file becomes a download tile.
  Future<void> _addPastedFiles(List<DroppedFile> files) async {
    if (_note?.trashed ?? false) return;
    await _uploadAll(files, failureMessage: "Couldn't upload the pasted files");
  }

  Future<void> _editReminder() async {
    if (_reminderPickerOpen) return;
    _reminderPickerOpen = true;
    try {
      final settings = context.read<SettingsStore>();
      final selection = await ReminderPicker.show(
        context,
        current: _note?.reminderAt,
        currentRepeat: _note?.reminderRepeat,
        currentLocation: settings.locationReminderForNote(_noteId),
        savedLocations: settings.savedLocations,
        locationSupported: LocationGeofences.supported,
        use24hTime: settings.use24hTime,
      );
      if (!mounted || selection == null) return;
      if (selection.locationId != null) {
        final granted = await LocationGeofences.instance
            .requestReminderPermissions();
        if (!mounted) return;
        if (!granted) {
          showAppSnack(
            'Allow notifications and “all the time” location access so this '
            'reminder can fire while Skippy is closed.',
            icon: Icons.location_disabled_outlined,
            kind: SnackKind.warning,
          );
          return;
        }
        _ensureNote();
        final added = settings.setLocationReminder(
          _noteId!,
          selection.locationId!,
          selection.locationTrigger!,
        );
        if (!added) {
          showAppSnack(
            'You can have up to 20 active location reminders.',
            icon: Icons.location_disabled_outlined,
            kind: SnackKind.warning,
          );
          return;
        }
        _store.setReminder(_noteId!, null);
        setState(() {});
        return;
      }
      if (selection.at != null) _ensureNote();
      if (_noteId == null) return;
      settings.removeLocationReminder(_noteId!);
      _store.setReminder(_noteId!, selection.at, selection.repeat);
      setState(() {});
    } finally {
      _reminderPickerOpen = false;
    }
  }

  Future<void> _openShare() async {
    final note = _note;
    if (note == null || note.isEmpty) {
      showAppSnack('Add some content before sharing');
      return;
    }
    final left = await ShareDialog.show(context, note.id);
    if (left && mounted) Navigator.of(context).pop();
  }

  // -------------------------------------------------------------------
  // External (collaborator/undo) updates for the plain text fields

  void _syncTextFields() {
    final note = _note;
    if (note == null) return;
    if (!_titleFocus.hasFocus && _titleController.text != note.title) {
      _restoring = true;
      _titleController.text = note.title;
      _restoring = false;
    }
    if (_kind != NoteKind.checklist &&
        !_contentFocus.hasFocus &&
        _contentController.text != note.content) {
      _restoring = true;
      _contentController.text = note.content;
      _restoring = false;
    }
  }

  // -------------------------------------------------------------------
  // Build

  int get _matchCount {
    final q = _findController.text.trim().toLowerCase();
    final note = _note;
    if (q.isEmpty || note == null) return 0;
    if (note.isChecklist) {
      return note.items.where((i) => i.text.toLowerCase().contains(q)).length;
    }
    return note.content.toLowerCase().split(q).length - 1;
  }

  /// Enters find-in-note mode with the search field focused.
  ///
  /// `autofocus` alone does not do it: it only claims focus when nothing else
  /// in the scope holds it, so opening search while the caret was in the note
  /// left focus on the note — you typed your query into the note itself. The
  /// field does not exist until this rebuild lands, hence the post-frame ask.
  void _openFind() {
    setState(() => _finding = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _finding) _findFocus.requestFocus();
    });
  }

  /// Leaves find-in-note mode, releasing the keyboard with it. Dropping the
  /// field from the tree is not enough: focus returns to whatever held it
  /// before (usually the note's own text field), so the keyboard stays up over
  /// a note you are no longer typing in.
  void _closeFind() {
    FocusManager.instance.primaryFocus?.unfocus();
    _findController.clear();
    setState(() => _finding = false);
  }

  /// Top bar: find-in-note mode swaps every action for a close button;
  /// otherwise trashed notes get restore/delete and live ones can be pinned.
  AppBar _buildAppBar(Note? note) {
    final trashed = note?.trashed ?? false;
    final pinned = note?.pinned ?? false;
    final scheme = Theme.of(context).colorScheme;
    final isOwner = note?.isOwnedBy(_store.currentUserId) ?? true;
    final autoDiscardable = note == null || _store.canAutoDiscard(note.id);
    return AppBar(
      backgroundColor: Colors.transparent,
      // Full-screen editors are the phone presentation. A quiet rule keeps
      // their action bar visually separate from the editable note below;
      // desktop modals remain one compact surface.
      bottom: widget.modal
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(
                key: const Key('editor-top-separator'),
                height: 1,
                color: hairlineColor(scheme),
              ),
            ),
      leading: widget.modal
          ? CloseButton(onPressed: () => Navigator.of(context).maybePop())
          : BackButton(onPressed: () => Navigator.of(context).maybePop()),
      title: _finding
          ? TextField(
              controller: _findController,
              focusNode: _findFocus,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Find in note',
                border: InputBorder.none,
                suffixText: _findController.text.trim().isEmpty
                    ? null
                    : '$_matchCount found',
              ),
            )
          : null,
      actions: [
        if (_finding)
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close search',
            onPressed: _closeFind,
          )
        else ...[
          if (_kind == NoteKind.markdown)
            IconButton(
              icon: Icon(
                _previewMarkdown
                    ? Icons.edit_outlined
                    : Icons.visibility_outlined,
              ),
              tooltip: _previewMarkdown ? 'Edit markdown' : 'Preview',
              onPressed: () =>
                  setState(() => _previewMarkdown = !_previewMarkdown),
            ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find in note',
            onPressed: _openFind,
          ),
          if (!trashed) ...[
            IconButton(
              icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              tooltip: pinned ? 'Unpin' : 'Pin',
              onPressed: _togglePin,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.restore_from_trash_outlined),
              tooltip: 'Restore',
              onPressed: () {
                _store.restoreFromTrash(note!.id);
                Navigator.of(context).pop();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_forever_outlined),
              tooltip: 'Delete forever',
              onPressed: () {
                _store.deleteForever(note!.id);
                Navigator.of(context).pop();
                showAppSnack(
                  'Note deleted forever',
                  icon: Icons.delete_forever_outlined,
                  kind: SnackKind.danger,
                );
              },
            ),
          ],
          // Promoted out of the menu below: the two note actions used often
          // enough to earn a permanent target, kept adjacent to it so the
          // whole group still reads as "things you do to this note".
          IconButton(
            icon: const Icon(Icons.content_copy_outlined),
            tooltip: 'Copy to clipboard',
            onPressed: note == null || note.isEmpty
                ? null
                : _copyNoteToClipboard,
          ),
          if (!trashed)
            IconButton(
              icon: Icon(
                (note?.archived ?? false)
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              tooltip: (note?.archived ?? false) ? 'Unarchive' : 'Archive',
              onPressed: autoDiscardable ? null : _archiveAndClose,
            ),
          // Everything else you do *to* the note. The bottom bar keeps what
          // goes *into* it, so neither menu has to nest.
          NoteActionsButton(
            isOwner: isOwner,
            kind: _kind,
            onShare: trashed ? null : _openShare,
            onDelete: trashed || autoDiscardable || !isOwner
                ? null
                : _deleteAndClose,
            onDuplicate: trashed || note == null || note.isEmpty
                ? null
                : _duplicateNote,
            onMoveToWorkspace:
                trashed ||
                    note == null ||
                    note.isEmpty ||
                    !isOwner ||
                    _store.workspaces.length < 2
                ? null
                : () => MoveToWorkspaceSheet.show(context, note.id),
            // Unlike workspaces, a column needs no second one to move to,
            // "Unassigned" is always a destination, so this only asks that
            // there be a board at all.
            onMoveToStage:
                !widget.openedFromBoard ||
                    trashed ||
                    note == null ||
                    note.isEmpty ||
                    _store.stages.isEmpty
                ? null
                : () => MoveToStageSheet.show(context, note.id),
            onHistory: note == null || note.isEmpty
                ? null
                : () => NoteHistoryScreen.open(context, note.id),
            // A trashed note must not be pinnable: the widget would outlive
            // the note itself.
            onAddToHomeScreen: HomeWidgets.supported && !trashed
                ? _addToHomeScreen
                : null,
            onConvert: trashed ? null : _convertKind,
            onRewrite:
                trashed ||
                    note == null ||
                    note.isEmpty ||
                    note.isAudio ||
                    !_settings.noteWritingAvailable
                ? null
                : _rewriteWithAi,
            rewriting: note != null && _store.isRewritingNote(note.id),
          ),
        ],
        const SizedBox(width: 4),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch so external changes (labels, collaborator edits) rebuild.
    context.watch<NotesStore>();
    final settings = context.watch<SettingsStore>();
    final note = _note;

    // The note vanished under us (deleted elsewhere / we left it).
    if (_noteId != null && note == null && !_closing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    _syncTextFields();

    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final fill = note == null
        ? null
        : settings.resolveColor(note.color, brightness);
    final bg = fill ?? scheme.surface;
    final trashed = note?.trashed ?? false;
    final query = _finding ? _findController.text.trim() : '';

    final labels = [
      for (final id in note?.labelIds ?? const <String>{})
        if (_store.labelById(id) case final Label label) label,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return PopScope(
      // Release the keyboard the instant the close starts (close button,
      // system back, swipe-back, modal barrier tap) instead of when the
      // route finishes disposing, otherwise it lingers through the whole
      // closing animation and can stay stuck up.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) FocusManager.instance.primaryFocus?.unfocus();
      },
      child: PasteFileArea(
        enabled: !trashed,
        onFiles: _addPastedFiles,
        child: FileDropArea(
          hint: 'Drop files to attach',
          onFiles: _addDroppedFiles,
          child: AnimatedContainer(
            duration: Motion.base,
            curve: Motion.standard,
            color: bg,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                    _undo,
                const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
                    _undo,
                const SingleActivator(
                  LogicalKeyboardKey.keyZ,
                  control: true,
                  shift: true,
                ): _redo,
                const SingleActivator(
                  LogicalKeyboardKey.keyZ,
                  meta: true,
                  shift: true,
                ): _redo,
                const SingleActivator(LogicalKeyboardKey.keyY, control: true):
                    _redo,
              },
              child: _editorShell(
                note: note,
                body: SafeArea(
                  // heightFactor 1 makes the modal hug its content instead of
                  // stretching to the dialog's max height; fullscreen keeps the
                  // usual fill (the column is max-size there anyway).
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: widget.modal ? 1.0 : null,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: Column(
                        // Modal: shrink to the note's content (the dialog grows
                        // with the note) instead of
                        // filling the screen.
                        mainAxisSize: widget.modal
                            ? MainAxisSize.min
                            : MainAxisSize.max,
                        children: [
                          Flexible(
                            fit: widget.modal ? FlexFit.loose : FlexFit.tight,
                            child: GestureDetector(
                              onTap: trashed
                                  ? () => showAppSnack(
                                      "Can't edit in Trash, restore the note first",
                                    )
                                  : null,
                              child: ListView(
                                shrinkWrap: widget.modal,
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  8,
                                  24,
                                  24,
                                ),
                                children: [
                                  TextField(
                                    controller: _titleController,
                                    focusNode: _titleFocus,
                                    readOnly: trashed,
                                    enabled: !trashed,
                                    maxLines: null,
                                    textInputAction: TextInputAction.next,
                                    contentInsertionConfiguration:
                                        PasteFileArea.insertionOf(context),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                    decoration: const InputDecoration(
                                      hintText: 'Title',
                                      border: InputBorder.none,
                                    ),
                                  ),
                                  _contentEditor(
                                    trashed: trashed,
                                    query: query,
                                  ),
                                  // Images sit directly under the text; other
                                  // files follow as download tiles.
                                  ..._buildAttachments(note),
                                  if (note != null &&
                                      (note.reminderAt != null ||
                                          settings.locationReminderForNote(
                                                note.id,
                                              ) !=
                                              null ||
                                          labels.isNotEmpty))
                                    _metaChips(note, settings, labels),
                                  // Rich preview cards for any links in the
                                  // note, kept as the very last thing so they
                                  // always sit below everything else.
                                  if (note != null &&
                                      _linkText(note).isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: LinkPreviewList(
                                        text: _linkText(note),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          // Formatting accessory bar while editing markdown.
                          if (_kind == NoteKind.markdown &&
                              !_previewMarkdown &&
                              !_finding &&
                              !trashed)
                            MarkdownToolbar(
                              controller: _contentController,
                              focusNode: _contentFocus,
                            ),
                          if (_uploading)
                            const LinearProgressIndicator(minHeight: 2),
                          DecoratedBox(
                            key: widget.modal
                                ? null
                                : const Key('editor-bottom-separator'),
                            decoration: BoxDecoration(
                              border: widget.modal
                                  ? null
                                  : Border(
                                      top: BorderSide(
                                        color: hairlineColor(scheme),
                                      ),
                                    ),
                            ),
                            child: EditorBottomBar(
                              trashed: trashed,
                              editedStamp: note == null
                                  ? ''
                                  : 'Edited ${settings.editedLabel(note.updatedAt)}',
                              onPalette: trashed
                                  ? null
                                  : () => ColorPickerSheet.show(
                                      context,
                                      selected: () => _note?.color ?? 'default',
                                      onSelect: _setColor,
                                    ),
                              // Labelling is available from the first moment,
                              // like colour and pin: filing a note is often the
                              // first thing you do, and the draft materializes
                              // on demand.
                              onLabels: trashed ? null : _editLabels,
                              onReminder: trashed ? null : _editReminder,
                              onImage: trashed || _uploading
                                  ? null
                                  : _pickImage,
                              onAttach: trashed || _uploading
                                  ? null
                                  : _pickFile,
                              onUndo: trashed || !_history.canUndo
                                  ? null
                                  : _undo,
                              onRedo: trashed || !_history.canRedo
                                  ? null
                                  : _redo,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Fullscreen: a regular Scaffold. Modal: no Scaffold, it would expand to
  /// the dialog's max height, so a min-height column lets the dialog hug the
  /// note's content.
  Widget _editorShell({required Note? note, required Widget body}) {
    if (!widget.modal) {
      final scaffold = Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _buildAppBar(note),
        body: body,
      );
      // Wide layouts use a dialog with a close button. On a narrow fullscreen
      // editor, match the familiar mobile back gesture without competing with
      // horizontal controls anywhere other than the screen edge.
      if (wantsModalEditor(context)) return scaffold;
      return RawGestureDetector(
        gestures: {
          _EdgeDismissGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                _EdgeDismissGestureRecognizer
              >(
                () =>
                    _EdgeDismissGestureRecognizer(edgeWidth: _edgeDismissWidth),
                (recognizer) {
                  recognizer
                    ..onStart = _onEdgeSwipeStart
                    ..onUpdate = _onEdgeSwipeUpdate
                    ..onEnd = _onEdgeSwipeEnd
                    ..onCancel = _resetEdgeSwipe;
                },
              ),
        },
        child: scaffold,
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAppBar(note),
          Flexible(child: body),
        ],
      ),
    );
  }

  void _onEdgeSwipeStart(DragStartDetails _) {
    _edgeSwipeDistance = 0;
    _edgeSwipeDismissed = false;
  }

  void _onEdgeSwipeUpdate(DragUpdateDetails details) {
    _edgeSwipeDistance += details.delta.dx;
    if (_edgeSwipeDistance >= _edgeDismissDistance) {
      _dismissFromEdgeSwipe();
    }
  }

  void _onEdgeSwipeEnd(DragEndDetails details) {
    if (details.velocity.pixelsPerSecond.dx >= _edgeDismissFlingVelocity) {
      _dismissFromEdgeSwipe();
    }
    _resetEdgeSwipe();
  }

  void _dismissFromEdgeSwipe() {
    if (_edgeSwipeDismissed) return;
    _edgeSwipeDismissed = true;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).maybePop();
  }

  void _resetEdgeSwipe() {
    _edgeSwipeDistance = 0;
  }

  /// The note's main content area: checklist rows, rendered markdown
  /// preview, or the (highlightable) plain text field.
  Widget _contentEditor({required bool trashed, required String query}) {
    if (_kind == NoteKind.audio) {
      return _audioEditor(trashed: trashed, query: query);
    }
    if (_kind == NoteKind.checklist) {
      return AnimatedChecklist(
        items: _items,
        readOnly: trashed,
        autofocusNew:
            (widget.noteId == null && widget.kind == NoteKind.checklist) ||
            (widget.addChecklistItem && !trashed),
        highlightQuery: query,
        // Suggestions come from THIS note's checked history only, never
        // from other notes.
        suggestionsFor: (q, exclude) =>
            _store.suggestionsFor(_noteId, q, exclude: exclude),
        onToggle: _toggleItem,
        onItemTextChanged: _updateItemText,
        onRemove: _removeItem,
        onAdd: _addItem,
        onInsertAfter: _insertItemAfter,
        onReorderItems: _setItems,
      );
    }
    if (_kind == NoteKind.markdown && _previewMarkdown) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        // MarkdownBody's selectable mode owns the selection paint and gesture
        // handling. Wrapping it in a SelectionArea creates a second, offset
        // selection highlight on web.
        child: MarkdownBody(
          data: _contentController.text.isEmpty
              ? '*Nothing to preview*'
              : _contentController.text,
          selectable: true,
          // A tap on preview text returns to its markdown source. Drag and
          // long-press gestures remain owned by the selectable text.
          onTapText: trashed ? null : _editMarkdownFromPreview,
          onTapLink: (text, href, title) {
            if (href != null) {
              launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
            }
          },
        ),
      );
    }
    return HighlightedTextField(
      controller: _contentController,
      focusNode: _contentFocus,
      readOnly: trashed,
      query: query,
      monospace: _kind == NoteKind.markdown,
      // Focus is requested after the open transition settles (see initState)
      // so iOS doesn't raise the keyboard mid-animation.
      autofocus: false,
    );
  }

  void _editMarkdownFromPreview() {
    setState(() => _previewMarkdown = false);
    // The TextField only exists after the mode change has rebuilt. Requesting
    // focus on the next frame keeps the shortcut reliable on every platform.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _contentFocus.requestFocus();
    });
  }

  /// Audio note: the clip player on top, then the transcript, a live
  /// "Transcribing…" animation while Whisper runs, a retry affordance if it
  /// failed, otherwise the transcript as an editable text field.
  Widget _audioEditor({required bool trashed, required String query}) {
    final note = _note;
    final clip = note?.audioClip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (clip != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: AudioPlayerBar(url: _store.fileUrl(clip)),
          ),
        if (note?.transcribing ?? false)
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 8),
            child: TranscribingIndicator(),
          )
        else ...[
          if (note?.transcriptFailed ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: TranscriptFailed(
                onRetry: trashed || _noteId == null
                    ? null
                    : () => _store.retranscribe(_noteId!),
              ),
            ),
          HighlightedTextField(
            controller: _contentController,
            focusNode: _contentFocus,
            readOnly: trashed,
            query: query,
            autofocus: false,
          ),
        ],
      ],
    );
  }

  /// Reminder and label chips shown under the note content.
  Widget _metaChips(Note note, SettingsStore settings, List<Label> labels) {
    final trashed = note.trashed;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (note.reminderAt != null)
            InputChip(
              avatar: const Icon(Icons.alarm, size: 16),
              label: Text(_reminderLabel(note, settings)),
              visualDensity: VisualDensity.compact,
              onPressed: trashed ? null : _editReminder,
              onDeleted: trashed
                  ? null
                  : () {
                      _store.setReminder(note.id, null);
                      setState(() {});
                    },
            ),
          if (settings.locationReminderForNote(note.id)
              case final locationReminder?)
            if (settings.savedLocationById(locationReminder.locationId)
                case final location?)
              InputChip(
                avatar: const Icon(Icons.location_on_outlined, size: 16),
                label: Text(
                  '${locationReminder.trigger.label} · ${location.name}',
                ),
                visualDensity: VisualDensity.compact,
                onPressed: trashed ? null : _editReminder,
                onDeleted: trashed
                    ? null
                    : () {
                        settings.removeLocationReminder(note.id);
                        setState(() {});
                      },
              ),
          for (final label in labels)
            _labelChip(context, label, trashed, note.id),
        ],
      ),
    );
  }

  String _reminderLabel(Note note, SettingsStore settings) =>
      '${settings.reminderLabel(note.reminderAt!)}'
      '${note.reminderRepeat == null ? '' : ' · ${note.reminderRepeat!.label}'}';

  /// One label chip in the editor, tinted with the label's colour and prefixed
  /// with its icon (custom or default).
  Widget _labelChip(
    BuildContext context,
    Label label,
    bool trashed,
    String noteId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final tint = labelColor(label, scheme.onSurfaceVariant);
    final tinted = label.color != null;
    return InputChip(
      avatar: Icon(labelIcon(label), size: 16, color: tint),
      label: Text(label.name),
      visualDensity: VisualDensity.compact,
      backgroundColor: tinted ? tint.withValues(alpha: 0.12) : null,
      side: tinted ? BorderSide(color: tint.withValues(alpha: 0.55)) : null,
      onDeleted: trashed
          ? null
          : () => _store.toggleLabelOnNote(noteId, label.id),
      onPressed: trashed ? null : () => LabelsSheet.show(context, noteId),
    );
  }

  /// The note's title + body, but only when it actually contains a URL, an
  /// empty string otherwise so the preview strip is skipped entirely.
  String _linkText(Note note) {
    final combined = '${note.title}\n${note.content}';
    return findUrls(combined).isEmpty ? '' : combined;
  }

  /// Images render inline, in upload order; every other file becomes a
  /// download tile below them. Files still mid-upload render as placeholder
  /// tiles in the same two groups, after their real counterparts, so a pick
  /// shows up immediately instead of only once the network call resolves.
  List<Widget> _buildAttachments(Note? note) {
    final pendingImages = _pendingUploads.where(
      (f) => f.mime.startsWith('image/'),
    );
    final pendingFiles = _pendingUploads.where(
      (f) => !f.mime.startsWith('image/'),
    );
    if ((note == null || note.attachments.isEmpty) && _pendingUploads.isEmpty) {
      return const [];
    }
    final attachments = note?.attachments ?? const <Attachment>[];
    final trashed = note?.trashed ?? false;
    VoidCallback? remove(Attachment attachment) => trashed
        ? null
        : () {
            _store.removeAttachment(note!.id, attachment.id);
            setState(() {});
          };
    return [
      for (final attachment in attachments.where((a) => a.isImage))
        ImageAttachmentTile(
          attachment: attachment,
          url: _store.fileUrl(attachment),
          onRemove: remove(attachment),
        ),
      for (final file in pendingImages) UploadingAttachmentTile(file: file),
      // Audio clips are played by the audio-note body, not listed as files.
      for (final attachment in attachments.where(
        (a) => !a.isImage && !a.isAudio,
      ))
        FileAttachmentTile(
          attachment: attachment,
          url: _store.fileUrl(attachment),
          onRemove: remove(attachment),
        ),
      for (final file in pendingFiles) UploadingAttachmentTile(file: file),
    ];
  }
}

/// A horizontal drag recognizer that only enters the gesture arena when the
/// touch starts at the screen's left edge. The editor can therefore offer an
/// Android/iOS-style back swipe without stealing normal horizontal gestures.
class _EdgeDismissGestureRecognizer extends HorizontalDragGestureRecognizer {
  _EdgeDismissGestureRecognizer({required this.edgeWidth});

  final double edgeWidth;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.position.dx <= edgeWidth) {
      super.addAllowedPointer(event);
    }
  }
}

/// How to add a widget where the app cannot do it itself.
///
/// iOS exposes no API for placing a widget, so this walks through the system
/// gesture instead. Naming the note in the last step matters: the widget's own
/// picker is where the note is actually chosen, and it is not obvious that the
/// choice happens there rather than here.
class _AddToHomeScreenHelp extends StatelessWidget {
  const _AddToHomeScreenHelp({required this.noteTitle});

  final String noteTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = [
      'Touch and hold an empty area of your Home Screen.',
      'Tap the + button in the corner.',
      'Search for Skippy and pick a widget size.',
    ];
    return AlertDialog(
      icon: const Icon(Icons.widgets_outlined),
      title: const Text('Add a Skippy widget'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _Step(number: i + 1, text: steps[i]),
            ),
          _Step(
            number: steps.length + 1,
            text:
                'Touch and hold the new widget, tap Edit Widget, '
                'then choose "$noteTitle".',
          ),
          const SizedBox(height: 12),
          Text(
            'Checklist items can be ticked straight from the widget.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}
