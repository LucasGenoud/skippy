import 'package:animations/animations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/editor_history.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/linkify.dart';
import '../util/mime.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'history_screen.dart';
import '../widgets/animated_checklist.dart';
import '../widgets/audio_player.dart';
import '../widgets/color_picker.dart';
import '../widgets/editor/attachment_tiles.dart';
import '../widgets/editor/editor_bottom_bar.dart';
import '../widgets/editor/highlighted_text_field.dart';
import '../widgets/file_drop.dart';
import '../widgets/labels_sheet.dart';
import '../widgets/link_preview.dart';
import '../widgets/markdown_toolbar.dart';
import '../widgets/share_dialog.dart';
import '../widgets/transcribing_indicator.dart';

/// Full-screen note editor. Everything autosaves as you type (the store
/// debounces the network write); empty notes are discarded on close, exactly
/// on wide layouts.
///
/// With [noteId] null this is the "new note" editor: the note is only created
/// in the store on the first actual change, so backing out of an untouched
/// editor never produces a phantom note.
///
/// The editor keeps a session history of the note's content — undo/redo
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

  const EditorScreen({
    super.key,
    this.noteId,
    this.kind = NoteKind.text,
    this.modal = false,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

/// Whether this layout opens notes as a centered modal
/// instead of fullscreen. Same breakpoint as the quick-add bar.
bool wantsModalEditor(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 600;

/// Open the editor for the current layout: a centered
/// fade-scale modal over a dimmed barrier on wide screens, or the given
/// fullscreen container-transform ([openFullscreen], from an enclosing
/// OpenContainer) on narrow ones. Dismissing the modal — barrier tap,
/// Escape, or the close button — finalizes the note exactly like popping
/// the fullscreen editor.
Future<void> openNoteEditor(
  BuildContext context, {
  required VoidCallback openFullscreen,
  String? noteId,
  NoteKind kind = NoteKind.text,
}) {
  // Drop focus from whatever field held it (search bar, quick-add, chat
  // composer). Without this the enclosing FocusScope remembers that field
  // and hands focus straight back when the editor pops — resummoning the
  // soft keyboard right as the note closes.
  FocusManager.instance.primaryFocus?.unfocus();
  if (!wantsModalEditor(context)) {
    openFullscreen();
    return Future<void>.value();
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close note',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeScaleTransition(animation: animation, child: child),
    pageBuilder: (context, animation, secondaryAnimation) => Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadius),
          child: EditorScreen(noteId: noteId, kind: kind, modal: true),
        ),
      ),
    ),
  );
}

class _EditorScreenState extends State<EditorScreen> {
  static const _uuid = Uuid();

  late final NotesStore _store;
  late final TextEditingController _titleController;
  late final LinkifyingController _contentController;
  final _findController = TextEditingController();
  final _titleFocus = FocusNode();
  final _contentFocus = FocusNode();

  String? _noteId;
  bool _closing = false;
  bool _finding = false;
  bool _uploading = false;
  bool _previewMarkdown = false;
  final Map<int, Offset> _previewPointerStarts = {};
  Duration? _lastPreviewTapTime;
  Offset? _lastPreviewTapPosition;

  // Undo/redo session history (see EditorHistory for the grouping rules).
  late final EditorHistory _history;
  bool _restoring = false;

  Note? get _note => _noteId == null ? null : _store.noteById(_noteId!);

  @override
  void initState() {
    super.initState();
    _store = context.read<NotesStore>();
    _noteId = widget.noteId;
    final note = _note;
    _titleController = TextEditingController(text: note?.title ?? '');
    _contentController = LinkifyingController(
      text: note?.content ?? '',
      onOpenUrl: launchLinkUrl,
    );
    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    _findController.addListener(() => setState(() {}));
    _history = EditorHistory(_currentSnapshot());
    // A brand-new text/markdown note wants the body focused for immediate
    // typing. But focusing on mount makes iOS raise the keyboard while the open
    // transition (container morph / fade-scale modal) is still animating —
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
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Lifecycle

  NoteKind get _kind => _note?.kind ?? widget.kind;

  void _ensureNote() {
    if (_noteId != null) return;
    _noteId = _store.createDraft(kind: widget.kind).id;
  }

  void _finalize() {
    if (_closing) return;
    _closing = true;
    if (_noteId == null) {
      showAppSnack('Empty note discarded');
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
    final discarded = _store.finalizeNote(_noteId!);
    if (discarded) showAppSnack('Empty note discarded');
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
    setState(() {});
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

  void _archiveAndClose() {
    final note = _note;
    if (note == null || note.isEmpty) return;
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

  void _copyNote() {
    final note = _note;
    if (note == null || note.isEmpty) return;
    _store.duplicate(note.id);
    showAppSnack('Note copied', icon: Icons.copy_outlined);
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
        await _store.uploadFile(id, f.bytes, f.mime, f.name);
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
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _uploadAll([
        DroppedFile(
          name: picked.name,
          mime: picked.mimeType ?? mimeFromName(picked.name),
          bytes: await picked.readAsBytes(),
        ),
      ], failureMessage: "Couldn't upload the image");
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

  Future<void> _editReminder() async {
    final note = _note;
    if (note?.reminderAt != null) {
      final action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Change reminder'),
                onTap: () => Navigator.pop(context, 'change'),
              ),
              ListTile(
                leading: const Icon(Icons.alarm_off),
                title: const Text('Remove reminder'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      );
      if (action == 'remove') {
        _store.setReminder(_noteId!, null);
        setState(() {});
        return;
      }
      if (action != 'change') return;
    }
    await _pickReminder();
  }

  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final initial =
        _note?.reminderAt ?? DateTime(now.year, now.month, now.day + 1, 9);
    if (!mounted) return;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 5)),
      helpText: 'Remind me on',
    );
    if (date == null || !mounted) return;
    final use24h = context.read<SettingsStore>().use24hTime;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Remind me at',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
        child: child!,
      ),
    );
    if (time == null) return;
    _ensureNote();
    _store.setReminder(
      _noteId!,
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
    setState(() {});
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

  /// Top bar: find-in-note mode swaps every action for a close button;
  /// otherwise trashed notes get restore/delete and live ones can be pinned.
  AppBar _buildAppBar(Note? note) {
    final trashed = note?.trashed ?? false;
    final pinned = note?.pinned ?? false;
    return AppBar(
      backgroundColor: Colors.transparent,
      leading: widget.modal
          ? CloseButton(onPressed: () => Navigator.of(context).maybePop())
          : BackButton(onPressed: () => Navigator.of(context).maybePop()),
      title: _finding
          ? TextField(
              controller: _findController,
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
            onPressed: () {
              _findController.clear();
              setState(() => _finding = false);
            },
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
            onPressed: () => setState(() => _finding = true),
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
                showAppSnack(
                  'Note restored',
                  icon: Icons.restore_outlined,
                  kind: SnackKind.success,
                );
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
    final isOwner = note?.isOwnedBy(_store.currentUserId) ?? true;
    final isRewriting = note != null && _store.isRewritingNote(note.id);
    final query = _finding ? _findController.text.trim() : '';

    final labels = [
      for (final id in note?.labelIds ?? const <String>{})
        if (_store.labelById(id) case final Label label) label,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return PopScope(
      // Release the keyboard the instant the close starts (close button,
      // system back, swipe-back, modal barrier tap) instead of when the
      // route finishes disposing — otherwise it lingers through the whole
      // closing animation and can stay stuck up.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) FocusManager.instance.primaryFocus?.unfocus();
      },
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
              const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
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
                                    "Can't edit in Trash — restore the note first",
                                  )
                                : null,
                            child: ListView(
                              shrinkWrap: widget.modal,
                              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                              children: [
                                TextField(
                                  controller: _titleController,
                                  focusNode: _titleFocus,
                                  readOnly: trashed,
                                  enabled: !trashed,
                                  maxLines: null,
                                  textInputAction: TextInputAction.next,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                  decoration: const InputDecoration(
                                    hintText: 'Title',
                                    border: InputBorder.none,
                                  ),
                                ),
                                _contentEditor(trashed: trashed, query: query),
                                // Images sit directly under the text; other
                                // files follow as download tiles.
                                ..._buildAttachments(note),
                                // Rich preview cards for any links in the note.
                                if (note != null && _linkText(note).isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: LinkPreviewList(
                                      text: _linkText(note),
                                    ),
                                  ),
                                if (note != null &&
                                    (note.reminderAt != null ||
                                        labels.isNotEmpty))
                                  _metaChips(note, settings, labels),
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
                        EditorBottomBar(
                          trashed: trashed,
                          isOwner: isOwner,
                          archived: note?.archived ?? false,
                          kind: _kind,
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
                          onLabels: trashed || note == null || note.isEmpty
                              ? null
                              : () => LabelsSheet.show(context, note.id),
                          onReminder: trashed ? null : _editReminder,
                          onImage: trashed || _uploading ? null : _pickImage,
                          onAttach: trashed || _uploading ? null : _pickFile,
                          onShare: trashed ? null : _openShare,
                          onArchive: trashed || note == null || note.isEmpty
                              ? null
                              : _archiveAndClose,
                          onUndo: trashed || !_history.canUndo ? null : _undo,
                          onRedo: trashed || !_history.canRedo ? null : _redo,
                          onDelete:
                              trashed ||
                                  note == null ||
                                  note.isEmpty ||
                                  !isOwner
                              ? null
                              : _deleteAndClose,
                          onCopy: trashed || note == null || note.isEmpty
                              ? null
                              : _copyNote,
                          onHistory: note == null || note.isEmpty
                              ? null
                              : () => NoteHistoryScreen.open(context, note.id),
                          onConvert: trashed ? null : _convertKind,
                          onRewrite:
                              trashed ||
                                  note == null ||
                                  note.isEmpty ||
                                  note.isAudio ||
                                  !settings.noteWritingAvailable
                              ? null
                              : _rewriteWithAi,
                          rewriting: isRewriting,
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
    );
  }

  /// Fullscreen: a regular Scaffold. Modal: no Scaffold — it would expand to
  /// the dialog's max height — so a min-height column lets the dialog hug the
  /// note's content.
  Widget _editorShell({required Note? note, required Widget body}) {
    if (!widget.modal) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _buildAppBar(note),
        body: body,
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
            widget.noteId == null && widget.kind == NoteKind.checklist,
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
        // A MarkdownBody with `selectable: true` creates a separate selection
        // scope for every rendered block. SelectionArea keeps one scope around
        // the whole preview, so a drag can cross line and paragraph breaks.
        child: Listener(
          // Listen rather than join the gesture arena: SelectionArea keeps
          // ownership of drag/long-press selection while two ordinary clicks
          // still provide the explicit edit shortcut.
          behavior: HitTestBehavior.translucent,
          onPointerDown: trashed ? null : _recordPreviewPointerDown,
          onPointerUp: trashed ? null : _handlePreviewPointerUp,
          onPointerCancel: trashed ? null : _clearPreviewPointer,
          child: SelectionArea(
            child: MarkdownBody(
              data: _contentController.text.isEmpty
                  ? '*Nothing to preview*'
                  : _contentController.text,
              onTapLink: (text, href, title) {
                if (href != null) {
                  launchUrl(
                    Uri.parse(href),
                    mode: LaunchMode.externalApplication,
                  );
                }
              },
            ),
          ),
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

  void _recordPreviewPointerDown(PointerDownEvent event) {
    _previewPointerStarts[event.pointer] = event.position;
  }

  void _clearPreviewPointer(PointerCancelEvent event) {
    _previewPointerStarts.remove(event.pointer);
  }

  void _handlePreviewPointerUp(PointerUpEvent event) {
    final start = _previewPointerStarts.remove(event.pointer);
    // A drag belongs to text selection, never to the double-click shortcut.
    if (start == null || (event.position - start).distance > kTouchSlop) {
      return;
    }
    final previousTime = _lastPreviewTapTime;
    final previousPosition = _lastPreviewTapPosition;
    final isDoubleClick =
        previousTime != null &&
        previousPosition != null &&
        event.timeStamp - previousTime <= kDoubleTapTimeout &&
        (event.position - previousPosition).distance <= kDoubleTapSlop;
    _lastPreviewTapTime = isDoubleClick ? null : event.timeStamp;
    _lastPreviewTapPosition = isDoubleClick ? null : event.position;
    if (isDoubleClick) _editMarkdownFromPreview();
  }

  /// Audio note: the clip player on top, then the transcript — a live
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
              label: Text(settings.reminderLabel(note.reminderAt!)),
              visualDensity: VisualDensity.compact,
              onPressed: trashed ? null : _editReminder,
              onDeleted: trashed
                  ? null
                  : () {
                      _store.setReminder(note.id, null);
                      setState(() {});
                    },
            ),
          for (final label in labels)
            _labelChip(context, label, trashed, note.id),
        ],
      ),
    );
  }

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

  /// The note's title + body, but only when it actually contains a URL — an
  /// empty string otherwise so the preview strip is skipped entirely.
  String _linkText(Note note) {
    final combined = '${note.title}\n${note.content}';
    return findUrls(combined).isEmpty ? '' : combined;
  }

  /// Images render inline, in upload order; every other file becomes a
  /// download tile below them.
  List<Widget> _buildAttachments(Note? note) {
    if (note == null || note.attachments.isEmpty) return const [];
    VoidCallback? remove(Attachment attachment) => note.trashed
        ? null
        : () {
            _store.removeAttachment(note.id, attachment.id);
            setState(() {});
          };
    return [
      for (final attachment in note.attachments.where((a) => a.isImage))
        ImageAttachmentTile(
          attachment: attachment,
          url: _store.fileUrl(attachment),
          onRemove: remove(attachment),
        ),
      // Audio clips are played by the audio-note body, not listed as files.
      for (final attachment in note.attachments.where(
        (a) => !a.isImage && !a.isAudio,
      ))
        FileAttachmentTile(
          attachment: attachment,
          url: _store.fileUrl(attachment),
          onRemove: remove(attachment),
        ),
    ];
  }
}
