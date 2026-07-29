import 'dart:async';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/note_conversion.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/mime.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'animated_checklist.dart';
import 'app_logo.dart';
import 'color_picker.dart';
import 'file_drop.dart';
import 'labels_sheet.dart';
import 'markdown_toolbar.dart';
import 'reminder_picker.dart';
import 'share_dialog.dart';

/// Inline quick add, shown above the grid on wide screens: pick a kind and
/// compose the whole note inline — plain text, a checklist, or markdown —
/// without ever leaving the grid. Close / tap outside / Escape all save (an
/// empty composer just collapses). The image icon creates an image note
/// straight from the file dialog.
///
/// Everything a note can carry is available while composing: colour, labels,
/// a reminder, images and files, collaborators, pinning, archiving and
/// conversion between kinds. All of it is held locally until the note is
/// created on save, so an abandoned composer never leaves a phantom note in
/// the grid — and, because a draft is created with these already set, they
/// ride along on the create request instead of trailing behind it.
class QuickAddBar extends StatefulWidget {
  /// Labels the composed note starts with — set when a label view is open, so
  /// what you write there stays there.
  final Set<String> labelIds;

  const QuickAddBar({super.key, this.labelIds = const {}});

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  static const _uuid = Uuid();

  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  late final FocusNode _titleFocus;
  final _contentFocus = FocusNode();

  bool _expanded = false;
  NoteKind _kind = NoteKind.text;

  /// Local draft items while composing a checklist inline; committed to a real
  /// note only on save.
  List<ChecklistItem> _items = [];
  bool _uploading = false;

  // The note's own properties, composed locally and applied when the note is
  // created. Reset with the rest of the composer.
  String _color = 'default';
  Set<String> _labelIds = {};
  DateTime? _reminderAt;
  bool _pinned = false;
  final List<DroppedFile> _files = [];

  /// True while a picker, sheet or menu of ours is open. Those open their own
  /// route, and the tap that lands on it reads as a tap outside the composer —
  /// which would otherwise save and collapse it mid-action.
  bool _modalOpen = false;

  @override
  void initState() {
    super.initState();
    _titleFocus = FocusNode(onKeyEvent: _handleTitleKey);
  }

  KeyEventResult _handleTitleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        _kind != NoteKind.checklist) {
      _contentFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _titleFocus.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  void _expand(NoteKind kind) {
    setState(() {
      _expanded = true;
      _kind = kind;
      // A note composed in a label view is filed there from the start; the
      // chips show it, and it can be unfiled like any other label.
      _labelIds = {...widget.labelIds};
    });
    // The checklist grabs focus itself (its new-item row); text/markdown need
    // the content field focused once it exists.
    if (kind != NoteKind.checklist) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expanded) _contentFocus.requestFocus();
      });
    }
  }

  /// Whether there is anything worth turning into a note. A reminder counts on
  /// its own: it is an alarm the user deliberately set, and [Note.isEmpty]
  /// keeps such a note alive for the same reason.
  bool get _hasContent {
    if (_titleController.text.trim().isNotEmpty) return true;
    if (_files.isNotEmpty || _reminderAt != null) return true;
    if (_kind == NoteKind.checklist) {
      return _items.any((i) => i.text.trim().isNotEmpty);
    }
    return _contentController.text.trim().isNotEmpty;
  }

  /// Create the note from everything composed so far, or return null when
  /// there is nothing worth keeping. Does not collapse the composer.
  String? _commit() {
    if (!_hasContent) return null;
    final store = context.read<NotesStore>();
    final note = store.createDraft(kind: _kind, labelIds: _labelIds);
    // Properties first, while the note is still a draft: drafts are never
    // PATCHed, so everything set here rides along on the create request that
    // the content update below triggers.
    if (_color != 'default') store.setColor(note.id, _color);
    if (_reminderAt != null) store.setReminder(note.id, _reminderAt);
    if (_pinned) store.togglePin(note.id);
    if (_kind == NoteKind.checklist) {
      store.updateNoteContent(
        note.id,
        title: _titleController.text,
        items: [
          for (final i in _items)
            if (i.text.trim().isNotEmpty) i,
        ],
      );
    } else {
      store.updateNoteContent(
        note.id,
        title: _titleController.text,
        content: _contentController.text,
      );
    }
    if (_files.isNotEmpty) unawaited(_uploadFiles(store, note.id, [..._files]));
    return note.id;
  }

  /// Uploads what was picked while composing, once the note it belongs to has
  /// been created — the same path the editor's paperclip takes, including the
  /// force-create for a note whose only content is its files.
  Future<void> _uploadFiles(
    NotesStore store,
    String noteId,
    List<DroppedFile> files,
  ) async {
    for (final file in files) {
      try {
        await store.uploadFile(noteId, file.bytes, file.mime, file.name);
      } catch (_) {
        showAppSnack(
          "Couldn't upload ${file.name}",
          icon: Icons.error_outline,
          kind: SnackKind.danger,
        );
      }
    }
  }

  /// Closing always saves what's there.
  void _saveAndCollapse() {
    if (!_expanded || _modalOpen) return;
    _commit();
    _reset();
  }

  void _reset() {
    _titleController.clear();
    _contentController.clear();
    _contentFocus.unfocus();
    setState(() {
      _items = [];
      _kind = NoteKind.text;
      _expanded = false;
      _color = 'default';
      _labelIds = {};
      _reminderAt = null;
      _pinned = false;
      _files.clear();
    });
  }

  // ---------------------------------------------------------------------
  // Inline checklist editing on the local draft list

  void _setItems(List<ChecklistItem> items) => setState(() => _items = items);

  String _addItem(String text) {
    final item = ChecklistItem(id: _uuid.v4(), text: text.trim());
    _setItems([..._items, item]);
    return item.id;
  }

  void _updateItem(String id, String text) => _setItems([
    for (final i in _items) i.id == id ? i.copyWith(text: text) : i,
  ]);

  void _toggleItem(String id) => _setItems([
    for (final i in _items) i.id == id ? i.copyWith(done: !i.done) : i,
  ]);

  void _removeItem(String id) =>
      _setItems(_items.where((i) => i.id != id).toList());

  String _insertAfter(String afterId) {
    final items = [..._items];
    final index = items.indexWhere((i) => i.id == afterId);
    final item = ChecklistItem(id: _uuid.v4(), text: '');
    items.insert(index < 0 ? items.length : index + 1, item);
    _setItems(items);
    return item.id;
  }

  // ---------------------------------------------------------------------
  // Note actions

  /// Runs [action] with the outside-tap collapse suppressed — see [_modalOpen].
  Future<void> _withModal(Future<void> Function() action) async {
    _modalOpen = true;
    try {
      await action();
    } finally {
      _modalOpen = false;
    }
  }

  Future<void> _pickColor() => _withModal(
    () => ColorPickerSheet.show(
      context,
      selected: () => _color,
      onSelect: (color) => setState(() => _color = color),
    ),
  );

  Future<void> _editLabels() => _withModal(
    () => LabelsSheet.showForSelection(
      context,
      selected: _labelIds,
      onToggle: (labelId) => setState(() {
        _labelIds.contains(labelId)
            ? _labelIds.remove(labelId)
            : _labelIds.add(labelId);
      }),
    ),
  );

  Future<void> _editReminder() => _withModal(() async {
    final selection = await ReminderPicker.show(
      context,
      current: _reminderAt,
      use24hTime: context.read<SettingsStore>().use24hTime,
    );
    if (!mounted || selection == null) return;
    setState(() => _reminderAt = selection.at);
  });

  /// Files picked while composing wait here until the note is created, so a
  /// composer that is closed without saving uploads nothing.
  void _addFiles(List<DroppedFile> picked) {
    final kept = <DroppedFile>[];
    var oversized = false;
    for (final file in picked) {
      if (file.bytes.length > maxUploadBytes) {
        oversized = true;
      } else {
        kept.add(file);
      }
    }
    if (oversized) showAppSnack('Files are limited to 25 MB');
    if (kept.isEmpty) return;
    setState(() => _files.addAll(kept));
  }

  Future<void> _addImage() => _withModal(() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      _addFiles([
        DroppedFile(
          name: picked.name,
          mime: picked.mimeType ?? mimeFromName(picked.name),
          bytes: bytes,
        ),
      ]);
    } catch (_) {
      showAppSnack("Couldn't add the image");
    }
  });

  Future<void> _attachFiles() => _withModal(() async {
    try {
      final picked = await pickAnyFiles();
      if (!mounted) return;
      _addFiles(picked);
    } catch (_) {
      showAppSnack("Couldn't add the file");
    }
  });

  /// Sharing needs a real note, so this saves first and hands the created note
  /// to the dialog.
  Future<void> _share() => _withModal(() async {
    if (!_hasContent) {
      showAppSnack('Add some content before sharing');
      return;
    }
    final id = _commit();
    _reset();
    if (id != null && mounted) await ShareDialog.show(context, id);
  });

  void _archive() {
    final store = context.read<NotesStore>();
    final id = _commit();
    _reset();
    if (id == null) return;
    store.setArchived(id, true);
    showAppSnack(
      'Note archived',
      icon: Icons.archive_outlined,
      actionLabel: 'Undo',
      onAction: () => store.setArchived(id, false),
    );
  }

  void _discard() {
    final hadContent = _hasContent;
    _reset();
    if (hadContent) {
      showAppSnack('Note discarded', icon: Icons.delete_outline);
    }
  }

  /// Convert what has been composed so far to another kind, running the same
  /// pure transformation the editor uses.
  void _convert(NoteKind target) {
    if (target == _kind) return;
    final now = DateTime.now();
    final converted = convertNoteKind(
      Note(
        id: '',
        kind: _kind,
        title: _titleController.text,
        content: _contentController.text,
        items: _items,
        createdAt: now,
        updatedAt: now,
      ),
      target,
      newItemId: _uuid.v4,
    );
    _contentController.text = converted.content;
    setState(() {
      _kind = target;
      _items = converted.items;
    });
    if (target != NoteKind.checklist) _contentFocus.requestFocus();
  }

  Future<void> _quickImageNote() async {
    final store = context.read<NotesStore>();
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > maxUploadBytes) {
        showAppSnack('Files are limited to 25 MB');
        return;
      }
      setState(() => _uploading = true);
      final id = await store.createNoteWithFiles([
        DroppedFile(
          name: picked.name,
          mime: picked.mimeType ?? mimeFromName(picked.name),
          bytes: bytes,
        ),
      ], labelIds: widget.labelIds);
      if (id == null) showAppSnack("Couldn't upload the image");
    } catch (_) {
      showAppSnack("Couldn't upload the image");
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = context.watch<SettingsStore>().resolveColor(
      _color,
      Theme.of(context).brightness,
    );
    // Expanding is a pleasant, deliberate reveal. Closing follows a focus
    // loss, however, and must get out of the way immediately — otherwise the
    // still-visible composer makes the page feel like it ignored the click.
    return TapRegion(
      onTapOutside: (_) => _saveAndCollapse(),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _saveAndCollapse,
        },
        child: Material(
          color: fill ?? scheme.surface,
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: AnimatedSize(
            // Ease the open/close on the Material-3 emphasized bezier so the
            // bar unfurls into the composer rather than snapping linearly.
            // A zero reverse duration trips an AnimatedSize layout assertion,
            // so one millisecond is used: visually instant, framework-safe.
            duration: Motion.base,
            reverseDuration: const Duration(milliseconds: 1),
            curve: Motion.emphasized,
            alignment: Alignment.topCenter,
            // Cross-fade bar <-> composer while the size animates, so the
            // expansion reads as one motion instead of a hard content swap.
            child: AnimatedSwitcher(
              duration: Motion.base,
              reverseDuration: Duration.zero,
              switchInCurve: Motion.emphasized,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (currentChild, previousChildren) => Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [...previousChildren, ?currentChild],
              ),
              child: _expanded
                  ? KeyedSubtree(
                      key: const ValueKey('composer'),
                      child: _buildComposer(context),
                    )
                  : KeyedSubtree(
                      key: const ValueKey('bar'),
                      child: _buildBar(context),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget kindButton(IconData icon, String tooltip, NoteKind kind) =>
        IconButton(
          icon: Icon(icon, size: 22),
          color: scheme.onSurfaceVariant,
          tooltip: tooltip,
          onPressed: () => _expand(kind),
        );

    // A plain tap target instead of an InkWell: clicking the collapsed bar
    // only expands the composer, and a ripple splashing across it on desktop
    // felt wrong for something that reads as a text input. The text cursor
    // reinforces the input affordance; the icon buttons keep their own.
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _expand(NoteKind.text),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              const AppLogo(size: 22),
              const SizedBox(width: kSpaceSm),
              Expanded(
                child: Text(
                  'Take a note…',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              kindButton(
                Icons.check_box_outlined,
                'New checklist',
                NoteKind.checklist,
              ),
              kindButton(
                Icons.notes_outlined,
                'New markdown note',
                NoteKind.markdown,
              ),
              if (_uploading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 11),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.image_outlined, size: 22),
                  color: scheme.onSurfaceVariant,
                  tooltip: 'New note with image',
                  onPressed: _quickImageNote,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _titleController,
                      focusNode: _titleFocus,
                      maxLines: null,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                        if (_kind != NoteKind.checklist) {
                          _contentFocus.requestFocus();
                        }
                      },
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Title',
                        border: InputBorder.none,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    ),
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    tooltip: _pinned ? 'Unpin' : 'Pin',
                    onPressed: () => setState(() => _pinned = !_pinned),
                  ),
                ],
              ),
              _composerBody(context),
              _pendingFiles(context),
              _metaChips(context),
            ],
          ),
        ),
        if (_kind == NoteKind.markdown)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: MarkdownToolbar(
              controller: _contentController,
              focusNode: _contentFocus,
            ),
          ),
        _actionBar(context),
      ],
    );
  }

  Widget _composerBody(BuildContext context) {
    if (_kind == NoteKind.checklist) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: AnimatedChecklist(
          items: _items,
          autofocusNew: true,
          // A quick-add note has no id yet, so there is no per-note history to
          // draw suggestions from.
          suggestionsFor: (_, _) => const [],
          onToggle: _toggleItem,
          onItemTextChanged: _updateItem,
          onRemove: _removeItem,
          onAdd: _addItem,
          onInsertAfter: _insertAfter,
          onReorderItems: _setItems,
        ),
      );
    }
    return TextField(
      controller: _contentController,
      focusNode: _contentFocus,
      maxLines: null,
      minLines: 2,
      style: _kind == NoteKind.markdown
          ? Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.4,
            )
          : Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
      decoration: InputDecoration(
        hintText: _kind == NoteKind.markdown ? 'Markdown…' : 'Take a note…',
        border: InputBorder.none,
        isCollapsed: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
      ),
    );
  }

  /// Images and files picked while composing, shown before they exist on the
  /// server. Each can be dropped again until the note is saved.
  Widget _pendingFiles(BuildContext context) {
    if (_files.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final file in _files)
            if (file.mime.startsWith('image/'))
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(kRadius),
                    child: Image.memory(
                      file.bytes,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => Container(
                        width: 72,
                        height: 72,
                        color: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _RemoveFileButton(
                      tooltip: 'Remove ${file.name}',
                      onPressed: () => setState(() => _files.remove(file)),
                    ),
                  ),
                ],
              )
            else
              InputChip(
                avatar: const Icon(Icons.insert_drive_file_outlined, size: 16),
                label: Text(file.name),
                visualDensity: VisualDensity.compact,
                onDeleted: () => setState(() => _files.remove(file)),
              ),
        ],
      ),
    );
  }

  /// The reminder and labels the note will be born with, as chips that can be
  /// edited or cleared — the same affordance the editor gives a saved note.
  Widget _metaChips(BuildContext context) {
    final store = context.watch<NotesStore>();
    final settings = context.watch<SettingsStore>();
    final scheme = Theme.of(context).colorScheme;
    final labels = [
      for (final id in _labelIds)
        if (store.labelById(id) case final Label label) label,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (_reminderAt == null && labels.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_reminderAt case final at?)
            InputChip(
              avatar: const Icon(Icons.alarm, size: 16),
              label: Text(settings.reminderLabel(at)),
              visualDensity: VisualDensity.compact,
              onPressed: _editReminder,
              onDeleted: () => setState(() => _reminderAt = null),
            ),
          for (final label in labels)
            InputChip(
              avatar: Icon(
                labelIcon(label),
                size: 16,
                color: labelColor(label, scheme.onSurfaceVariant),
              ),
              label: Text(label.name),
              visualDensity: VisualDensity.compact,
              backgroundColor: label.color == null
                  ? null
                  : labelColor(
                      label,
                      scheme.onSurfaceVariant,
                    ).withValues(alpha: 0.12),
              onPressed: _editLabels,
              onDeleted: () => setState(() => _labelIds.remove(label.id)),
            ),
        ],
      ),
    );
  }

  /// Everything a note can carry, available before it exists. The editor's
  /// remaining actions (history, duplicate, undo) need a saved note, so they
  /// live there rather than here.
  Widget _actionBar(BuildContext context) {
    Widget action({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
    }) => IconButton(
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onPressed,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          action(
            icon: Icons.palette_outlined,
            tooltip: 'Note color',
            onPressed: _pickColor,
          ),
          action(
            icon: Icons.label_outline,
            tooltip: 'Labels',
            onPressed: _editLabels,
          ),
          action(
            icon: Icons.notification_add_outlined,
            tooltip: 'Remind me',
            onPressed: _editReminder,
          ),
          action(
            icon: Icons.image_outlined,
            tooltip: 'Add image',
            onPressed: _addImage,
          ),
          action(
            icon: Icons.attach_file,
            tooltip: 'Attach file',
            onPressed: _attachFiles,
          ),
          action(
            icon: Icons.person_add_alt_outlined,
            tooltip: 'Collaborators',
            onPressed: _share,
          ),
          action(
            icon: Icons.archive_outlined,
            tooltip: 'Archive',
            onPressed: _archive,
          ),
          PopupMenuButton<String>(
            popUpAnimationStyle: Motion.menuFor(context),
            icon: const Icon(Icons.more_vert, size: 20),
            iconSize: 20,
            tooltip: 'More',
            onOpened: () => _modalOpen = true,
            onCanceled: () => _modalOpen = false,
            onSelected: _onMenuSelected,
            itemBuilder: (context) => [
              // Audio notes come from a recording, never a conversion target.
              for (final target in NoteKind.values)
                if (target != _kind && target != NoteKind.audio)
                  _menuItem(
                    value: 'convert:${target.name}',
                    icon: _kindIcons[target]!,
                    label: _kindLabels[target]!,
                  ),
              const PopupMenuDivider(),
              _menuItem(
                value: 'discard',
                icon: Icons.delete_outline,
                label: 'Discard note',
                color: Theme.of(context).colorScheme.error,
              ),
            ],
          ),
          const Spacer(),
          TextButton(onPressed: _saveAndCollapse, child: const Text('Close')),
        ],
      ),
    );
  }

  /// A menu row with a leading icon, matching the editor's overflow menu.
  /// [color] tints both icon and label (used to flag the destructive Discard).
  static PopupMenuItem<String> _menuItem({
    required String value,
    required IconData icon,
    required String label,
    Color? color,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: color == null ? null : TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }

  static const _kindLabels = {
    NoteKind.text: 'Convert to text note',
    NoteKind.checklist: 'Convert to checklist',
    NoteKind.markdown: 'Convert to markdown note',
  };

  static const _kindIcons = {
    NoteKind.text: Icons.notes_outlined,
    NoteKind.checklist: Icons.checklist,
    NoteKind.markdown: Icons.data_object,
  };

  Future<void> _onMenuSelected(String value) async {
    try {
      if (value == 'discard') {
        await Motion.waitForMenuDismissal(context);
        if (!mounted) return;
        _discard();
        return;
      }
      for (final target in NoteKind.values) {
        if (value == 'convert:${target.name}') _convert(target);
      }
    } finally {
      _modalOpen = false;
    }
  }
}

/// The small circular scrim button that removes a picked image.
class _RemoveFileButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onPressed;

  const _RemoveFileButton({required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(2),
          child: const Icon(Icons.close, size: 14, color: Colors.white),
        ),
      ),
    );
  }
}
