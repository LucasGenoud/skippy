import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/collection.dart';
import '../state/notes_store.dart';
import 'form_dialog.dart';

Future<NoteCollection?> editCollection(
  BuildContext context, {
  NoteCollection? collection,
}) async {
  final store = context.read<NotesStore>();
  final workspaceId = store.activeWorkspaceId;
  var name = collection?.name ?? '';
  var layout = collection?.layout ?? 'masonry';
  String? error;
  return showFormDialog<NoteCollection>(
    context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => FormDialog(
        title: Text(collection == null ? 'New collection' : 'Edit collection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: name,
              onChanged: (v) => name = v,
              autofocus: true,
              enabled: collection?.id != 'inbox',
              maxLength: 60,
              decoration: InputDecoration(labelText: 'Name', errorText: error),
            ),
            DropdownButtonFormField<String>(
              initialValue: layout,
              decoration: const InputDecoration(labelText: 'Layout'),
              items: const [
                DropdownMenuItem(value: 'masonry', child: Text('Masonry')),
                DropdownMenuItem(value: 'list', child: Text('List')),
                DropdownMenuItem(value: 'board', child: Text('Board')),
              ],
              onChanged: (value) => layout = value!,
            ),
          ],
        ),
        actions: [
          if (collection != null && collection.id != 'inbox')
            TextButton(
              onPressed: () async {
                final remove = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete collection?'),
                    content: const Text(
                      'Its notes move to Inbox and keep their labels. Its board columns are removed.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (remove != true ||
                    !context.mounted ||
                    store.activeWorkspaceId != workspaceId) {
                  return;
                }
                store.deleteCollection(collection.id);
                Navigator.pop(context, NoteCollection.inbox);
              },
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = name.trim();
              if (store.activeWorkspaceId != workspaceId) {
                Navigator.pop(context);
                return;
              }
              if (text.isEmpty ||
                  text.length > 60 ||
                  store.collections.any(
                    (c) =>
                        c.id != collection?.id &&
                        c.name.toLowerCase() == text.toLowerCase(),
                  )) {
                setState(
                  () => error = 'Use a unique name, up to 60 characters',
                );
                return;
              }
              final saved = collection == null
                  ? store.createCollection(text, layout)
                  : collection.copyWith(name: text, layout: layout);
              if (collection != null) {
                store.putCollection(saved);
              }
              Navigator.pop(context, saved);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> moveToCollection(
  BuildContext context,
  Iterable<String> noteIds,
) async {
  final store = context.read<NotesStore>();
  final workspaceId = store.activeWorkspaceId;
  final id = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Move to collection'),
      children: [
        for (final c in store.collections)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, c.id),
            child: Text(c.name),
          ),
      ],
    ),
  );
  if (id == null || store.activeWorkspaceId != workspaceId) {
    return;
  }
  store.moveNotesToCollection(noteIds, id);
}

class CollectionControls extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;
  final String title;
  final Set<String> selectedIds;
  const CollectionControls({
    super.key,
    required this.selection,
    required this.onSelect,
    required this.title,
    this.selectedIds = const {},
  });
  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final collection = store.collectionById(selection.collectionId);
    final saved = store.savedViewById(selection.savedViewId ?? '');
    final scope =
        collection?.name ??
        (saved?.collectionIds.isNotEmpty == true
            ? saved!.collectionIds
                  .map(
                    (id) =>
                        store.collectionById(id)?.name ?? 'Deleted collection',
                  )
                  .join(', ')
            : 'All collections');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              collection == null
                  ? '$scope › ${title.isEmpty ? 'All notes' : title}'
                  : collection.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selectedIds.isNotEmpty)
            IconButton(
              tooltip: 'Move to collection',
              onPressed: () => moveToCollection(context, selectedIds.toList()),
              icon: const Icon(Icons.drive_file_move_outlined),
            ),
          if (collection != null) ...[
            PopupMenuButton<String>(
              tooltip: 'Collection layout',
              initialValue: collection.layout,
              icon: Icon(
                collection.layout == 'board'
                    ? Icons.view_kanban_outlined
                    : collection.layout == 'list'
                    ? Icons.view_agenda_outlined
                    : Icons.dashboard_outlined,
              ),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'masonry', child: Text('Masonry')),
                PopupMenuItem(value: 'list', child: Text('List')),
                PopupMenuItem(value: 'board', child: Text('Board')),
              ],
              onSelected: (layout) {
                store.putCollection(collection.copyWith(layout: layout));
                onSelect(store.collectionSelection(collection.id));
              },
            ),
            IconButton(
              tooltip: 'Edit collection',
              icon: const Icon(Icons.more_horiz),
              onPressed: () async {
                final saved = await editCollection(
                  context,
                  collection: collection,
                );
                if (saved != null && context.mounted) {
                  onSelect(store.collectionSelection(saved.id));
                }
              },
            ),
          ] else ...[
            const Text('Add to: '),
            SizedBox(
              width: 120,
              child: DropdownButton<String>(
                isExpanded: true,
                value: store.composeCollectionId,
                underline: const SizedBox.shrink(),
                items: [
                  for (final c in store.collections)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(c.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) {
                  store.selectCollection(id);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
