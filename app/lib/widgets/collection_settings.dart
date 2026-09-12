import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/collection.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import 'form_dialog.dart';
import 'glyph_picker.dart';
import 'drag_reorder_list.dart';
import 'settings/accent_color.dart' show kAccentPresets;
import 'staggered_entrance.dart';
import '../theme.dart';

class ManageCollectionsDialog extends StatelessWidget {
  const ManageCollectionsDialog({super.key});

  static Future<void> show(BuildContext context) {
    final store = context.read<NotesStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: const ManageCollectionsDialog(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    return FormDialog(
      title: const Text('Manage collections'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.add),
            title: const Text('Create new collection'),
            onTap: () => CollectionSettings.show(context),
          ),
          const Divider(height: 8),
          DragReorderList<NoteCollection>(
            items: store.collections,
            idOf: (collection) => collection.id,
            onReorder: store.moveCollection,
            rowBuilder: (context, collection, index, handle) =>
                StaggeredEntrance(
                  index: index,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        handle,
                        const SizedBox(width: 4),
                        Icon(
                          collection.icon == null
                              ? Icons.folder_outlined
                              : labelIconFor(collection.icon),
                          color: PaletteEntry.hexToColor(collection.color),
                        ),
                      ],
                    ),
                    title: Text(
                      collection.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(switch (collection.layout) {
                      'board' => 'Board',
                      'list' => 'List',
                      _ => 'Masonry',
                    }),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => CollectionSettings.show(
                      context,
                      collection: collection,
                    ),
                  ),
                ),
          ),
        ],
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

class CollectionSettings extends StatefulWidget {
  final NoteCollection? collection;
  final String workspaceId;
  const CollectionSettings({
    super.key,
    this.collection,
    required this.workspaceId,
  });

  static Future<void> show(
    BuildContext context, {
    NoteCollection? collection,
    String? workspaceId,
  }) => showFormDialog<void>(
    context,
    builder: (_) => CollectionSettings(
      collection: collection,
      workspaceId:
          workspaceId ??
          collection?.workspaceId ??
          context.read<NotesStore>().activeWorkspaceId!,
    ),
  );

  @override
  State<CollectionSettings> createState() => _CollectionSettingsState();
}

class _CollectionSettingsState extends State<CollectionSettings> {
  late final _name = TextEditingController(text: widget.collection?.name ?? '');
  late String _layout = widget.collection?.layout ?? 'masonry';
  late String _sort = widget.collection?.sort ?? 'custom';
  late String? _icon = widget.collection?.icon;
  late String? _color = widget.collection?.color;
  late final _hex = TextEditingController(text: _color ?? '');
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _hex.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a collection name');
      return;
    }
    final store = context.read<NotesStore>();
    final c = NoteCollection(
      id: widget.collection?.id ?? const Uuid().v4(),
      workspaceId: widget.workspaceId,
      name: name,
      layout: _layout,
      sort: _sort,
      icon: _icon,
      color: _color,
      position:
          widget.collection?.position ?? store.collections.length * 1024.0,
    );
    store.saveCollection(c);
    store.selectCollection(c.id);
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final store = context.read<NotesStore>();
    final c = widget.collection!;
    final count = store
        .notesInWorkspace(c.workspaceId)
        .where((n) => n.collectionId == c.id && !n.trashed)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Delete ${c.name}?'),
        content: Text(
          '$count ${count == 1 ? 'note will' : 'notes will'} move to workspace trash. You can restore them to another collection for 7 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete collection'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    store.deleteCollection(c.id);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: Text(
      widget.collection == null ? 'New collection' : 'Collection settings',
    ),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: widget.collection == null,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            errorText: _error,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) {
            if (_error != null) {
              setState(() => _error = null);
            }
          },
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        const FormSectionLabel('Layout'),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'masonry', label: Text('Masonry')),
            ButtonSegment(value: 'list', label: Text('List')),
            ButtonSegment(value: 'board', label: Text('Board')),
          ],
          selected: {_layout},
          showSelectedIcon: false,
          onSelectionChanged: (values) =>
              setState(() => _layout = values.single),
        ),
        const SizedBox(height: 8),
        Text(
          'This layout is shared with everyone in the workspace.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _sort,
          decoration: const InputDecoration(
            labelText: 'Default sorting',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'custom', child: Text('Custom order')),
            DropdownMenuItem(value: 'edited', child: Text('Last edited')),
            DropdownMenuItem(value: 'newest', child: Text('Newest first')),
            DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
          ],
          onChanged: (v) => setState(() => _sort = v!),
        ),
        const Divider(height: 32),
        const FormSectionLabel('Color'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final color in <Color?>[null, ...kAccentPresets])
              Tooltip(
                message: color == null
                    ? 'Theme default'
                    : PaletteEntry.colorToHex(color),
                child: ColorDot(
                  color: color,
                  selected: PaletteEntry.hexToColor(_color) == color,
                  onTap: () => setState(() {
                    _color = color == null
                        ? null
                        : PaletteEntry.colorToHex(color);
                    _hex.text = _color ?? '';
                  }),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 150,
          child: TextField(
            controller: _hex,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Custom hex',
              hintText: '#RRGGBB',
            ),
            onChanged: (value) {
              final parsed = PaletteEntry.hexToColor(value);
              setState(
                () => _color = parsed == null
                    ? (value.trim().isEmpty ? null : _color)
                    : PaletteEntry.colorToHex(parsed),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        const FormSectionLabel('Icon'),
        const SizedBox(height: 10),
        IconGrid(
          selected: _icon,
          defaultIcon: Icons.folder_outlined,
          tint:
              PaletteEntry.hexToColor(_color) ??
              Theme.of(context).colorScheme.onSurfaceVariant,
          onSelect: (key) => setState(() => _icon = key),
        ),
        if (widget.collection != null) ...[
          const Divider(height: 32),
          TextButton.icon(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete collection'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

/// Uses the same destination chooser for moving and restoring notes.
class CollectionPicker {
  static Future<String?> show(
    BuildContext context,
    String workspaceId, {
    String? selectedId,
  }) {
    final collections =
        context.read<NotesStore>().workspaceById(workspaceId)?.collections ??
        [];
    return showAdaptiveSelectionSurface<String>(
      context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ModalHeader(title: 'Choose a collection'),
              const SizedBox(height: kSpaceSm),
              for (final c in collections)
                ListTile(
                  leading: Icon(
                    c.icon == null
                        ? Icons.folder_outlined
                        : labelIconFor(c.icon),
                    color: PaletteEntry.hexToColor(c.color),
                  ),
                  title: Text(c.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(switch (c.layout) {
                    'board' => 'Board',
                    'list' => 'List',
                    _ => 'Masonry',
                  }),
                  selected: c.id == selectedId,
                  trailing: c.id == selectedId ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, c.id),
                ),
              const SizedBox(height: kSpaceSm),
              if (collections.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Create a collection in this workspace first.'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> restore(BuildContext context, String noteId) async {
    final store = context.read<NotesStore>();
    final note = store.noteById(noteId);
    if (note == null) {
      return;
    }
    final exists =
        store
            .workspaceById(note.workspaceId)
            ?.collections
            .any((c) => c.id == note.collectionId) ??
        false;
    if (exists) {
      store.restoreFromTrash(noteId);
      return;
    }
    final id = await show(context, note.workspaceId);
    if (id != null) {
      store.restoreFromTrash(noteId, collectionId: id);
    }
  }
}
