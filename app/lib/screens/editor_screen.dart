import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/mime.dart';
import '../util/snack.dart';
import '../widgets/animated_checklist.dart';
import '../widgets/audio_player.dart';
import '../widgets/color_picker.dart';
import '../widgets/file_drop.dart';
import '../widgets/labels_sheet.dart';
import '../widgets/markdown_toolbar.dart';
import '../widgets/share_dialog.dart';
import '../widgets/transcribing_indicator.dart';

/// Full-screen note editor. Everything autosaves as you type (the store
/// debounces the network write); empty notes are discarded on close, exactly
/// like Keep.
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

/// Whether this layout opens notes as a centered modal (Keep's web behavior)
/// instead of fullscreen. Same breakpoint as the quick-add bar.
bool wantsModalEditor(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 600;

/// Open the editor the Keep way for the current layout: a centered
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
          borderRadius: BorderRadius.circular(16),
          child: EditorScreen(noteId: noteId, kind: kind, modal: true),
        ),
      ),
    ),
  );
}

/// One undo/redo step: the note's editable content at a point in time.
class _Snapshot {
  final NoteKind kind;
  final String title;
  final String content;
  final List<ChecklistItem> items;

  const _Snapshot({
    required this.kind,
    required this.title,
    required this.content,
    required this.items,
  });

  bool sameAs(_Snapshot other) =>
      kind == other.kind &&
      title == other.title &&
      content == other.content &&
      listEquals(items, other.items);
}

class _EditorScreenState extends State<EditorScreen> {
  static const _uuid = Uuid();
  static const _burstGap = Duration(milliseconds: 800);

  late final NotesStore _store;
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  final _findController = TextEditingController();
  final _titleFocus = FocusNode();
  final _contentFocus = FocusNode();

  String? _noteId;
  bool _closing = false;
  bool _finding = false;
  bool _uploading = false;
  bool _previewMarkdown = false;

  // Undo/redo session history.
  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];
  late _Snapshot _mirror;
  DateTime _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);
  bool _restoring = false;

  Note? get _note => _noteId == null ? null : _store.noteById(_noteId!);

  @override
  void initState() {
    super.initState();
    _store = context.read<NotesStore>();
    _noteId = widget.noteId;
    final note = _note;
    _titleController = TextEditingController(text: note?.title ?? '');
    _contentController = TextEditingController(text: note?.content ?? '');
    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
    _findController.addListener(() => setState(() {}));
    _mirror = _currentSnapshot();
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
    );
    _afterChange();
    setState(() {});
  }

  // -------------------------------------------------------------------
  // Undo / redo

  _Snapshot _currentSnapshot() {
    final note = _note;
    if (note != null) {
      return _Snapshot(
        kind: note.kind,
        title: note.title,
        content: note.content,
        items: List<ChecklistItem>.from(note.items),
      );
    }
    return _Snapshot(
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
    final current = _currentSnapshot();
    if (current.sameAs(_mirror)) return;
    final now = DateTime.now();
    if (discrete || now.difference(_lastEdit) > _burstGap) {
      _undoStack.add(_mirror);
      if (_undoStack.length > 100) _undoStack.removeAt(0);
      _redoStack.clear();
    }
    _lastEdit = now;
    _mirror = current;
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_currentSnapshot());
    _applySnapshot(_undoStack.removeLast());
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_currentSnapshot());
    _applySnapshot(_redoStack.removeLast());
  }

  void _applySnapshot(_Snapshot snapshot) {
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
    _mirror = snapshot;
    _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);
    _restoring = false;
    setState(() {});
  }

  // -------------------------------------------------------------------
  // Checklist editing

  List<ChecklistItem> get _items => _note?.items ?? const [];

  void _setItems(List<ChecklistItem> items, {bool discrete = true}) {
    _ensureNote();
    _store.updateNoteContent(_noteId!, items: items);
    _afterChange(discrete: discrete);
    setState(() {});
  }

  void _addItem(String text) {
    _setItems([..._items, ChecklistItem(id: _uuid.v4(), text: text.trim())]);
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
      actionLabel: 'Undo',
      onAction: () => _store.restoreFromTrash(id),
    );
  }

  void _copyNote() {
    final note = _note;
    if (note == null || note.isEmpty) return;
    _store.duplicate(note.id);
    showAppSnack('Note copied');
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
      showAppSnack('Files are limited to 25 MB');
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
      showAppSnack(failureMessage);
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
      showAppSnack("Couldn't upload the image");
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
      showAppSnack("Couldn't upload the file");
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
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Remind me at',
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
  /// otherwise trashed notes get restore/delete and live ones pin/archive.
  AppBar _buildAppBar(Note? note) {
    final trashed = note?.trashed ?? false;
    final pinned = note?.pinned ?? false;
    final archived = note?.archived ?? false;
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
            IconButton(
              icon: Icon(
                archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
              tooltip: archived ? 'Unarchive' : 'Archive',
              onPressed: note == null || note.isEmpty ? null : _archiveAndClose,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.restore_from_trash_outlined),
              tooltip: 'Restore',
              onPressed: () {
                _store.restoreFromTrash(note!.id);
                Navigator.of(context).pop();
                showAppSnack('Note restored');
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_forever_outlined),
              tooltip: 'Delete forever',
              onPressed: () {
                _store.deleteForever(note!.id);
                Navigator.of(context).pop();
                showAppSnack('Note deleted forever');
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
    final query = _finding ? _findController.text.trim() : '';

    final labels = [
      for (final id in note?.labelIds ?? const <String>{})
        if (_store.labelById(id) case final Label label) label,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return FileDropArea(
      hint: 'Drop files to attach',
      onFiles: _addDroppedFiles,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
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
                    // with the note, like Keep's web editor) instead of
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
                                style: Theme.of(context).textTheme.headlineSmall
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
                      _BottomBar(
                        trashed: trashed,
                        isOwner: isOwner,
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
                        onUndo: trashed || _undoStack.isEmpty ? null : _undo,
                        onRedo: trashed || _redoStack.isEmpty ? null : _redo,
                        onDelete:
                            trashed || note == null || note.isEmpty || !isOwner
                            ? null
                            : _deleteAndClose,
                        onCopy: trashed || note == null || note.isEmpty
                            ? null
                            : _copyNote,
                        onConvert: trashed ? null : _convertKind,
                      ),
                    ],
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
  /// note's content, Keep-style.
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
        child: MarkdownBody(
          data: _contentController.text.isEmpty
              ? '*Nothing to preview*'
              : _contentController.text,
          onTapLink: (text, href, title) {
            if (href != null) {
              launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
            }
          },
        ),
      );
    }
    return _HighlightedTextField(
      controller: _contentController,
      focusNode: _contentFocus,
      readOnly: trashed,
      query: query,
      monospace: _kind == NoteKind.markdown,
      autofocus: widget.noteId == null && widget.kind != NoteKind.checklist,
    );
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
            child: AudioPlayerBar(url: _store.fileUrl(clip.id)),
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
          _HighlightedTextField(
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
            InputChip(
              label: Text(label.name),
              visualDensity: VisualDensity.compact,
              onDeleted: trashed
                  ? null
                  : () => _store.toggleLabelOnNote(note.id, label.id),
              onPressed: trashed
                  ? null
                  : () => LabelsSheet.show(context, note.id),
            ),
        ],
      ),
    );
  }

  /// Images render inline, in upload order; every other file becomes a
  /// download tile below them.
  List<Widget> _buildAttachments(Note? note) {
    if (note == null || note.attachments.isEmpty) return const [];
    return [
      for (final attachment in note.attachments.where((a) => a.isImage))
        _imageAttachment(note, attachment),
      // Audio clips are played by the audio-note body, not listed as files.
      for (final attachment in note.attachments.where(
        (a) => !a.isImage && !a.isAudio,
      ))
        _fileAttachment(note, attachment),
    ];
  }

  Widget _imageAttachment(Note note, Attachment attachment) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SizedBox(
                width: double.infinity,
                child: Image.network(
                  _store.fileUrl(attachment.id),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Container(
                    height: 80,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            ),
            if (!note.trashed)
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.white,
                    tooltip: 'Remove image',
                    onPressed: () {
                      _store.removeAttachment(note.id, attachment.id);
                      setState(() {});
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fileAttachment(Note note, Attachment attachment) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => launchUrl(
            Uri.parse(_store.fileUrl(attachment.id)),
            mode: LaunchMode.externalApplication,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.filename.isEmpty
                            ? 'file'
                            : attachment.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        formatBytes(attachment.size),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.download_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                if (!note.trashed)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Remove file',
                    onPressed: () {
                      _store.removeAttachment(note.id, attachment.id);
                      setState(() {});
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Content field with find-in-note highlighting: matching substrings get a
/// tinted background while the search bar is open.
class _HighlightedTextField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final bool autofocus;
  final bool monospace;
  final String query;

  const _HighlightedTextField({
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.query,
    this.autofocus = false,
    this.monospace = false,
  });

  @override
  State<_HighlightedTextField> createState() => _HighlightedTextFieldState();
}

class _HighlightedTextFieldState extends State<_HighlightedTextField> {
  _HighlightingController? _highlighting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(
      height: 1.5,
      fontFamily: widget.monospace ? 'monospace' : null,
      fontSize: widget.monospace ? 14 : null,
    );

    if (widget.query.isEmpty) {
      _highlighting = null;
      return TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        readOnly: widget.readOnly,
        enabled: !widget.readOnly,
        maxLines: null,
        minLines: 6,
        autofocus: widget.autofocus,
        style: style,
        decoration: const InputDecoration(
          hintText: 'Note',
          border: InputBorder.none,
        ),
      );
    }

    // While searching, render through a proxy controller that shares the
    // real controller's value but paints highlights.
    _highlighting ??= _HighlightingController(widget.controller);
    _highlighting!.query = widget.query;
    return TextField(
      controller: _highlighting,
      readOnly: true, // editing pauses while the find bar is open
      maxLines: null,
      minLines: 6,
      style: style,
      decoration: const InputDecoration(
        hintText: 'Note',
        border: InputBorder.none,
      ),
    );
  }
}

class _HighlightingController extends TextEditingController {
  final TextEditingController source;
  String _query = '';

  _HighlightingController(this.source) : super(text: source.text) {
    source.addListener(_sync);
  }

  void _sync() => value = source.value;

  set query(String q) {
    if (q == _query) return;
    _query = q;
    notifyListeners();
  }

  @override
  void dispose() {
    source.removeListener(_sync);
    super.dispose();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final q = _query.toLowerCase();
    if (q.isEmpty || text.isEmpty) {
      return TextSpan(text: text, style: style);
    }
    final scheme = Theme.of(context).colorScheme;
    final highlight =
        style?.copyWith(
          backgroundColor: scheme.tertiaryContainer,
          color: scheme.onTertiaryContainer,
        ) ??
        TextStyle(backgroundColor: scheme.tertiaryContainer);
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    var start = 0;
    while (true) {
      final index = lower.indexOf(q, start);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + q.length),
          style: highlight,
        ),
      );
      start = index + q.length;
      if (start >= text.length) break;
    }
    return TextSpan(style: style, children: spans);
  }
}

class _BottomBar extends StatelessWidget {
  final bool trashed;
  final bool isOwner;
  final NoteKind kind;
  final String editedStamp;
  final VoidCallback? onPalette;
  final VoidCallback? onLabels;
  final VoidCallback? onReminder;
  final VoidCallback? onImage;
  final VoidCallback? onAttach;
  final VoidCallback? onShare;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;
  final void Function(NoteKind target)? onConvert;

  const _BottomBar({
    required this.trashed,
    required this.isOwner,
    required this.kind,
    required this.editedStamp,
    this.onPalette,
    this.onLabels,
    this.onReminder,
    this.onImage,
    this.onAttach,
    this.onShare,
    this.onUndo,
    this.onRedo,
    this.onDelete,
    this.onCopy,
    this.onConvert,
  });

  static const _kindLabels = {
    NoteKind.text: 'Convert to text note',
    NoteKind.checklist: 'Convert to checklist',
    NoteKind.markdown: 'Convert to markdown note',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Note color',
            onPressed: onPalette,
          ),
          IconButton(
            icon: const Icon(Icons.label_outline),
            tooltip: 'Labels',
            onPressed: onLabels,
          ),
          IconButton(
            icon: const Icon(Icons.notification_add_outlined),
            tooltip: 'Remind me',
            onPressed: onReminder,
          ),
          IconButton(
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Add image',
            onPressed: onImage,
          ),
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: 'Attach file',
            onPressed: onAttach,
          ),
          IconButton(
            icon: const Icon(Icons.person_add_alt_outlined),
            tooltip: 'Collaborators',
            onPressed: onShare,
          ),
          // Takes the whole middle band (not a third of it, the way two
          // Spacers flanking a Flexible would) so the stamp isn't needlessly
          // truncated to "Edit…".
          Expanded(
            child: Center(
              child: Text(
                editedStamp,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: onUndo,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: 'Redo',
            onPressed: onRedo,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'delete') onDelete?.call();
              if (value == 'copy') onCopy?.call();
              for (final target in NoteKind.values) {
                if (value == 'convert:${target.name}') onConvert?.call(target);
              }
            },
            itemBuilder: (context) => [
              // Audio notes come from a recording, never a conversion target.
              for (final target in NoteKind.values)
                if (target != kind && target != NoteKind.audio)
                  PopupMenuItem(
                    value: 'convert:${target.name}',
                    enabled: onConvert != null,
                    child: Text(_kindLabels[target]!),
                  ),
              PopupMenuItem(
                value: 'copy',
                enabled: onCopy != null,
                child: const Text('Make a copy'),
              ),
              if (isOwner)
                PopupMenuItem(
                  value: 'delete',
                  enabled: onDelete != null,
                  child: const Text('Delete'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
