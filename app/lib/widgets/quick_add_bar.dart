import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/notes_store.dart';
import '../util/mime.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'animated_checklist.dart';
import 'markdown_toolbar.dart';

/// Keep-style quick add, shown above the grid on wide screens: pick a kind and
/// compose the whole note inline — plain text, a checklist, or markdown —
/// without ever leaving the grid. Close / tap outside / Escape all save (an
/// empty composer just collapses). The image icon creates an image note
/// straight from the file dialog.
class QuickAddBar extends StatefulWidget {
  const QuickAddBar({super.key});

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
    });
    // The checklist grabs focus itself (its new-item row); text/markdown need
    // the content field focused once it exists.
    if (kind != NoteKind.checklist) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expanded) _contentFocus.requestFocus();
      });
    }
  }

  bool get _hasContent {
    if (_titleController.text.trim().isNotEmpty) return true;
    if (_kind == NoteKind.checklist) {
      return _items.any((i) => i.text.trim().isNotEmpty);
    }
    return _contentController.text.trim().isNotEmpty;
  }

  /// Keep behavior: closing always saves what's there.
  void _saveAndCollapse() {
    if (!_expanded) return;
    if (_hasContent) {
      final store = context.read<NotesStore>();
      final note = store.createDraft(kind: _kind);
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
    }
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
      ]);
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
          color: scheme.surface,
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
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
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
              TextField(
                controller: _titleController,
                focusNode: _titleFocus,
                maxLines: null,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) {
                  if (_kind != NoteKind.checklist) {
                    _contentFocus.requestFocus();
                  }
                },
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  hintText: 'Title',
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
              _composerBody(context),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: _saveAndCollapse,
                child: const Text('Close'),
              ),
            ],
          ),
        ),
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
}
