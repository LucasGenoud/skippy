import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';

/// Bottom sheet for assigning labels to a note, with inline creation —
/// typing a name that doesn't exist offers "Create `name`".
class LabelsSheet extends StatefulWidget {
  final String noteId;
  const LabelsSheet({super.key, required this.noteId});

  static Future<void> show(BuildContext context, String noteId) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: LabelsSheet(noteId: noteId),
      ),
    );
  }

  @override
  State<LabelsSheet> createState() => _LabelsSheetState();
}

class _LabelsSheetState extends State<LabelsSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final note = store.noteById(widget.noteId);
    if (note == null) return const SizedBox.shrink();

    final q = _query.trim().toLowerCase();
    final visible = store.labels
        .where((l) => q.isEmpty || l.name.toLowerCase().contains(q))
        .toList();
    final exactExists = store.labels.any((l) => l.name.toLowerCase() == q);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Label note',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: TextField(
                controller: _controller,
                autofocus: false,
                decoration: const InputDecoration(
                  hintText: 'Enter label name',
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: UnderlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (q.isNotEmpty && !exactExists)
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: Text('Create "${_query.trim()}"'),
                      onTap: () {
                        final label = store.createLabel(_query.trim());
                        store.toggleLabelOnNote(widget.noteId, label.id);
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
                  for (final label in visible)
                    CheckboxListTile(
                      value: note.labelIds.contains(label.id),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: Text(label.name),
                      onChanged: (_) =>
                          store.toggleLabelOnNote(widget.noteId, label.id),
                    ),
                  if (visible.isEmpty && q.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No labels yet — type a name to create one.'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The "Edit labels" management dialog reached from the drawer.
class EditLabelsDialog extends StatefulWidget {
  const EditLabelsDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const EditLabelsDialog(),
  );

  @override
  State<EditLabelsDialog> createState() => _EditLabelsDialogState();
}

class _EditLabelsDialogState extends State<EditLabelsDialog> {
  final _newController = TextEditingController();

  @override
  void dispose() {
    _newController.dispose();
    super.dispose();
  }

  void _create() {
    final store = context.read<NotesStore>();
    final name = _newController.text.trim();
    if (name.isEmpty) return;
    if (store.labels.any((l) => l.name.toLowerCase() == name.toLowerCase())) {
      return;
    }
    store.createLabel(name);
    _newController.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    return AlertDialog(
      title: const Text('Edit labels'),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: TextField(
                controller: _newController,
                decoration: const InputDecoration(
                  hintText: 'Create new label',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onSubmitted: (_) => _create(),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.check),
                tooltip: 'Create label',
                onPressed: _create,
              ),
            ),
            for (final label in store.labels)
              _EditLabelRow(key: ValueKey(label.id), labelId: label.id),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _EditLabelRow extends StatefulWidget {
  final String labelId;
  const _EditLabelRow({super.key, required this.labelId});

  @override
  State<_EditLabelRow> createState() => _EditLabelRowState();
}

class _EditLabelRowState extends State<_EditLabelRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final label = context.read<NotesStore>().labelById(widget.labelId);
    _controller = TextEditingController(text: label?.name ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commitRename() {
    final store = context.read<NotesStore>();
    final name = _controller.text.trim();
    final current = store.labelById(widget.labelId);
    if (current == null || name.isEmpty || name == current.name) return;
    store.renameLabel(widget.labelId, name);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<NotesStore>();
    return ListTile(
      leading: const Icon(Icons.label_outline),
      title: Focus(
        onFocusChange: (focused) {
          if (!focused) _commitRename();
        },
        child: TextField(
          controller: _controller,
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
          ),
          onSubmitted: (_) => _commitRename(),
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete label',
        onPressed: () => store.deleteLabel(widget.labelId),
      ),
    );
  }
}
