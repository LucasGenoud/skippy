import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/dropped_file.dart';
import '../models/note.dart';
import '../screens/editor_screen.dart';
import '../state/notes_store.dart';
import '../util/mime.dart';
import '../util/snack.dart';

/// Keep-style quick add, shown above the grid on wide screens: click
/// "Take a note…" and type without leaving the grid. Close / tap outside /
/// Escape all save (an empty composer just collapses). The checklist icon
/// opens the full checklist editor; the image icon creates an image note
/// straight from the file dialog.
class QuickAddBar extends StatefulWidget {
  const QuickAddBar({super.key});

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocus = FocusNode();
  bool _expanded = false;
  bool _uploading = false;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  void _expand() {
    setState(() => _expanded = true);
    // The content field only exists after this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _expanded) _contentFocus.requestFocus();
    });
  }

  /// Keep behavior: closing always saves what's there.
  void _saveAndCollapse() {
    if (!_expanded) return;
    final title = _titleController.text;
    final content = _contentController.text;
    if (title.trim().isNotEmpty || content.trim().isNotEmpty) {
      final store = context.read<NotesStore>();
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: title, content: content);
    }
    _titleController.clear();
    _contentController.clear();
    _contentFocus.unfocus();
    setState(() => _expanded = false);
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
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: _expanded ? _buildComposer(context) : _buildBar(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _expand,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Take a note…',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Tooltip(
              message: 'New checklist',
              child: OpenContainer<void>(
                transitionDuration: const Duration(milliseconds: 300),
                transitionType: ContainerTransitionType.fade,
                closedElevation: 0,
                openElevation: 0,
                closedColor: scheme.surface,
                middleColor: scheme.surface,
                openColor: scheme.surface,
                closedShape: const CircleBorder(),
                closedBuilder: (context, open) => SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.check_box_outlined,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                openBuilder: (context, close) =>
                    const EditorScreen(noteId: null, kind: NoteKind.checklist),
              ),
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
    );
  }

  Widget _buildComposer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _titleController,
            maxLines: null,
            textInputAction: TextInputAction.next,
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
          TextField(
            controller: _contentController,
            focusNode: _contentFocus,
            maxLines: null,
            minLines: 2,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
            decoration: const InputDecoration(
              hintText: 'Take a note…',
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
            ),
          ),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: _saveAndCollapse,
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
