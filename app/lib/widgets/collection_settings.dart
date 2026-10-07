import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/collection.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import 'form_dialog.dart';
import 'glyph_picker.dart';
import 'drag_reorder_list.dart';
import 'settings/accent_color.dart' show kAccentPresets;
import 'staggered_entrance.dart';
import 'state_cross_fade.dart';
import '../theme.dart';

/// How a collection lays its notes out, as the editor offers them.
enum _Layout {
  masonry('masonry', 'Masonry', Icons.dashboard_outlined),
  list('list', 'List', Icons.view_agenda_outlined),
  board('board', 'Board', Icons.view_kanban_outlined);

  final String wire;
  final String label;
  final IconData icon;

  const _Layout(this.wire, this.label, this.icon);

  static _Layout of(String wire) =>
      values.firstWhere((l) => l.wire == wire, orElse: () => masonry);
}

/// The open collection's header tile, which the index title lines up with.
const double _paneHeaderHeight = 40;

IconData _collectionIcon(NoteCollection c) =>
    c.icon == null ? Icons.folder_outlined : labelIconFor(c.icon);

/// Every collection in the workspace, to reorder and edit.
///
/// A phone gets a list that opens each collection as its own page. A wide
/// window keeps the list beside the open collection instead, so editing one
/// never stacks a second dialog on top of the first.
class ManageCollectionsDialog extends StatelessWidget {
  const ManageCollectionsDialog({super.key});

  static Future<void> show(BuildContext context) {
    final store = context.read<NotesStore>();
    if (!isNarrowScreen(context)) {
      return showDialog<void>(
        context: context,
        builder: (_) => ChangeNotifierProvider.value(
          value: store,
          child: const _CollectionsSplit(),
        ),
      );
    }
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
            contentPadding: kModalRowPadding,
            shape: kRoundedShape,
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
                    contentPadding: kModalRowPadding,
                    shape: kRoundedShape,
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        handle,
                        const SizedBox(width: 4),
                        Icon(
                          _collectionIcon(collection),
                          color: PaletteEntry.hexToColor(collection.color),
                        ),
                      ],
                    ),
                    title: Text(
                      collection.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_Layout.of(collection.layout).label),
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

/// The wide manager: the collections on the left, the open one on the right.
class _CollectionsSplit extends StatefulWidget {
  const _CollectionsSplit();

  static const double _width = 820;
  static const double _height = 620;
  static const double _indexWidth = 260;

  @override
  State<_CollectionsSplit> createState() => _CollectionsSplitState();
}

class _CollectionsSplitState extends State<_CollectionsSplit> {
  /// The open collection; null while a new one is being drafted.
  late String? _selectedId =
      context.read<NotesStore>().activeCollection?.id ??
      context.read<NotesStore>().collections.firstOrNull?.id;

  /// Where to go back to when a draft is abandoned.
  String? _beforeDraft;

  void _select(String? id) => setState(() => _selectedId = id);

  void _startDraft() => setState(() {
    _beforeDraft = _selectedId;
    _selectedId = null;
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final collections = store.collections;
    final selected = collections.where((c) => c.id == _selectedId).firstOrNull;
    // A collection deleted from here (or elsewhere) hands over to its
    // neighbour rather than leaving the pane empty.
    final drafting = _selectedId == null || selected == null;
    final height = math.min(
      _CollectionsSplit._height,
      MediaQuery.sizeOf(context).height * 0.85,
    );

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: _CollectionsSplit._width,
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _CollectionsSplit._indexWidth,
              child: _CollectionIndex(
                collections: collections,
                selectedId: drafting ? null : _selectedId,
                drafting: drafting,
                onSelect: _select,
                onCreate: _startDraft,
                onReorder: store.moveCollection,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: StateCrossFade(
                state: drafting ? null : selected.id,
                child: _CollectionPane(
                  key: ValueKey(drafting ? null : selected.id),
                  collection: drafting ? null : selected,
                  workspaceId: store.activeWorkspaceId!,
                  onCreated: _select,
                  onCancelDraft: collections.isEmpty
                      ? null
                      : () => _select(
                          _beforeDraft ?? collections.firstOrNull?.id,
                        ),
                  onDeleted: () => _select(
                    collections
                        .where((c) => c.id != _selectedId)
                        .firstOrNull
                        ?.id,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The left column of the wide manager.
class _CollectionIndex extends StatelessWidget {
  final List<NoteCollection> collections;
  final String? selectedId;
  final bool drafting;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final void Function(String id, int index) onReorder;

  const _CollectionIndex({
    required this.collections,
    required this.selectedId,
    required this.drafting,
    required this.onSelect,
    required this.onCreate,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // As tall as the open collection's header, so the two titles share
        // a line.
        Padding(
          padding: kModalTitlePadding,
          child: SizedBox(
            height: _paneHeaderHeight,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text('Collections', style: theme.textTheme.titleLarge),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kModalInset,
            kSpaceXs,
            kModalInset,
            kSpaceMd,
          ),
          child: Text(
            'Drag to reorder',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: kSpaceSm),
            child: DragReorderList<NoteCollection>(
              items: collections,
              idOf: (collection) => collection.id,
              onReorder: onReorder,
              rowBuilder: (context, collection, index, handle) => _IndexRow(
                collection: collection,
                handle: handle,
                selected: collection.id == selectedId,
                onTap: () => onSelect(collection.id),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(kSpaceSm),
          child: _SelectableRow(
            selected: drafting,
            onTap: onCreate,
            child: const ListTile(
              leading: Icon(Icons.add),
              title: Text('New collection'),
            ),
          ),
        ),
      ],
    );
  }
}

/// A row whose selection fill fades in rather than snapping, like the
/// settings index beside its open page.
class _SelectableRow extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _SelectableRow({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = selected ? 1.0 : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: target, end: target),
      duration: Motion.fast,
      curve: Motion.standard,
      builder: (context, t, child) => Material(
        color: Color.lerp(Colors.transparent, scheme.secondaryContainer, t),
        borderRadius: BorderRadius.circular(kRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: child),
      ),
      child: child,
    );
  }
}

class _IndexRow extends StatelessWidget {
  final NoteCollection collection;
  final Widget handle;
  final bool selected;
  final VoidCallback onTap;

  const _IndexRow({
    required this.collection,
    required this.handle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: _SelectableRow(
        selected: selected,
        onTap: onTap,
        child: Row(
          children: [
            handle,
            const SizedBox(width: kSpaceXs),
            Icon(
              _collectionIcon(collection),
              color: PaletteEntry.hexToColor(collection.color),
            ),
            const SizedBox(width: kSpaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    collection.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    _Layout.of(collection.layout).label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: kSpaceSm),
          ],
        ),
      ),
    );
  }
}

/// The editing state both editors share: the standalone dialog, which saves
/// on Save, and the wide manager's pane, which saves as you go.
mixin _CollectionEditing<T extends StatefulWidget> on State<T> {
  NoteCollection? get original;
  String get workspaceId;

  late final name = TextEditingController(text: original?.name ?? '');
  late String layout = original?.layout ?? _Layout.masonry.wire;
  late String sort = original?.sort ?? 'custom';
  late String? icon = original?.icon;
  late String? color = original?.color;
  // Without its '#': the field draws one of its own in front.
  late final hex = TextEditingController(text: _bareHex(color));

  static String _bareHex(String? hex) => hex?.replaceFirst('#', '') ?? '';
  String? nameError;

  /// Called after any field changes.
  void edited() {}

  @override
  void dispose() {
    name.dispose();
    hex.dispose();
    super.dispose();
  }

  void _set(VoidCallback change) {
    setState(change);
    edited();
  }

  /// The collection as edited, or null with [nameError] set when the name
  /// is missing.
  NoteCollection? collectionFromFields() {
    final trimmed = name.text.trim();
    if (trimmed.isEmpty) {
      setState(() => nameError = 'Enter a collection name');
      return null;
    }
    final store = context.read<NotesStore>();
    return NoteCollection(
      id: original?.id ?? const Uuid().v4(),
      workspaceId: workspaceId,
      name: trimmed,
      layout: layout,
      sort: sort,
      icon: icon,
      color: color,
      position: original?.position ?? store.collections.length * 1024.0,
    );
  }

  /// Asks first, then sends the collection's notes to the workspace trash.
  Future<bool> confirmDelete() async {
    final store = context.read<NotesStore>();
    final c = original!;
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
      return false;
    }
    store.deleteCollection(c.id);
    return true;
  }

  Widget fields(BuildContext context, {VoidCallback? onSubmit}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = PaletteEntry.hexToColor(color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: name,
          autofocus: original == null,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            errorText: nameError,
            isDense: true,
            counterText: '',
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => _set(() => nameError = null),
          onSubmitted: (_) => onSubmit?.call(),
        ),
        const SizedBox(height: kSpaceLg + kSpaceSm),
        const FormSectionLabel('Layout'),
        const SizedBox(height: kSpaceSm),
        SegmentedButton<String>(
          segments: [
            for (final l in _Layout.values)
              ButtonSegment(
                value: l.wire,
                icon: Icon(l.icon, size: 18),
                label: Text(l.label),
              ),
          ],
          selected: {layout},
          showSelectedIcon: false,
          expandedInsets: EdgeInsets.zero,
          onSelectionChanged: (values) => _set(() => layout = values.single),
        ),
        const SizedBox(height: kSpaceSm),
        Text(
          'Layout and sorting are shared with everyone in the workspace.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: kSpaceLg),
        DropdownButtonFormField<String>(
          initialValue: sort,
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
          onChanged: (v) => _set(() => sort = v!),
        ),
        const Divider(height: 40),
        // A colour that is not a preset is typed in beside the heading, so
        // the swatches keep a row of their own.
        Row(
          children: [
            const Expanded(child: FormSectionLabel('Color')),
            SizedBox(
              width: 124,
              child: Tooltip(
                message: 'Custom color',
                child: TextField(
                  controller: hex,
                  style: theme.textTheme.bodyMedium,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: 'RRGGBB',
                    prefixIcon: Icon(Icons.tag, size: 16),
                    prefixIconConstraints: BoxConstraints(minWidth: 32),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: kSpaceSm,
                      vertical: kSpaceSm,
                    ),
                  ),
                  onChanged: (value) {
                    final parsed = PaletteEntry.hexToColor(value);
                    _set(
                      () => color = parsed == null
                          ? (value.trim().isEmpty ? null : color)
                          : PaletteEntry.colorToHex(parsed),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: kSpaceSm),
        Wrap(
          spacing: kSpaceSm,
          runSpacing: kSpaceSm,
          children: [
            for (final preset in <Color?>[null, ...kAccentPresets])
              Tooltip(
                message: preset == null
                    ? 'Theme default'
                    : PaletteEntry.colorToHex(preset),
                child: ColorDot(
                  color: preset,
                  selected: tint == preset,
                  onTap: () => _set(() {
                    color = preset == null
                        ? null
                        : PaletteEntry.colorToHex(preset);
                    hex.text = _bareHex(color);
                  }),
                ),
              ),
          ],
        ),
        const SizedBox(height: kSpaceLg + kSpaceSm),
        const FormSectionLabel('Icon'),
        const SizedBox(height: kSpaceSm),
        IconGrid(
          selected: icon,
          defaultIcon: Icons.folder_outlined,
          tint: tint ?? scheme.onSurfaceVariant,
          onSelect: (key) => _set(() => icon = key),
        ),
      ],
    );
  }
}

/// The open collection in the wide manager. An existing one saves as it is
/// edited, the way the settings pages do; a new one waits for Create, since
/// it has no name to exist under until then.
class _CollectionPane extends StatefulWidget {
  final NoteCollection? collection;
  final String workspaceId;
  final ValueChanged<String> onCreated;
  final VoidCallback? onCancelDraft;
  final VoidCallback onDeleted;

  const _CollectionPane({
    super.key,
    required this.collection,
    required this.workspaceId,
    required this.onCreated,
    required this.onCancelDraft,
    required this.onDeleted,
  });

  @override
  State<_CollectionPane> createState() => _CollectionPaneState();
}

class _CollectionPaneState extends State<_CollectionPane>
    with _CollectionEditing {
  /// Typing a name saves once the typing pauses, not on every keystroke.
  static const _nameSaveDelay = Duration(milliseconds: 500);

  Timer? _pendingSave;

  @override
  NoteCollection? get original => widget.collection;

  @override
  String get workspaceId => widget.workspaceId;

  bool get _isNew => widget.collection == null;

  @override
  void edited() {
    if (_isNew) {
      return;
    }
    _pendingSave?.cancel();
    _pendingSave = Timer(_nameSaveDelay, _save);
  }

  @override
  void dispose() {
    // Leaving the collection, or closing the dialog, keeps what was typed.
    if (_pendingSave?.isActive ?? false) {
      _pendingSave!.cancel();
      _save();
    }
    super.dispose();
  }

  void _save() {
    if (name.text.trim().isEmpty) {
      return;
    }
    final store = context.read<NotesStore>();
    // Edits can land after the collection was deleted elsewhere.
    if (!store.collections.any((c) => c.id == original!.id)) {
      return;
    }
    store.saveCollection(collectionFromFields()!);
  }

  void _create() {
    final c = collectionFromFields();
    if (c == null) {
      return;
    }
    final store = context.read<NotesStore>();
    store.saveCollection(c);
    store.selectCollection(c.id);
    widget.onCreated(c.id);
  }

  Future<void> _delete() async {
    _pendingSave?.cancel();
    if (await confirmDelete()) {
      widget.onDeleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = PaletteEntry.hexToColor(color) ?? scheme.onSurfaceVariant;
    final title = name.text.trim();
    final glyph = icon == null ? Icons.folder_outlined : labelIconFor(icon);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The collection as the sidebar will show it, following every edit.
        Padding(
          padding: kModalTitlePadding,
          child: Row(
            children: [
              AnimatedContainer(
                duration: Motion.fast,
                curve: Motion.standard,
                width: _paneHeaderHeight,
                height: _paneHeaderHeight,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.14),
                  borderRadius: kBorderRadius,
                ),
                child: Icon(glyph, color: tint),
              ),
              const SizedBox(width: kSpaceMd),
              Expanded(
                child: Text(
                  _isNew && title.isEmpty ? 'New collection' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: modalBodyPadding(hasFooter: true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                fields(context, onSubmit: _isNew ? _create : _save),
                if (!_isNew) ...[
                  const Divider(height: 40),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete collection'),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        ModalFooter(
          children: _isNew
              ? [
                  if (widget.onCancelDraft != null)
                    TextButton(
                      onPressed: widget.onCancelDraft,
                      child: const Text('Cancel'),
                    ),
                  const SizedBox(width: kSpaceSm),
                  FilledButton(onPressed: _create, child: const Text('Create')),
                ]
              : [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
        ),
      ],
    );
  }
}

/// One collection on its own: from the shortcut, the empty state, a phone's
/// collection list, and the workspace settings.
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

class _CollectionSettingsState extends State<CollectionSettings>
    with _CollectionEditing {
  @override
  NoteCollection? get original => widget.collection;

  @override
  String get workspaceId => widget.workspaceId;

  void _save() {
    final c = collectionFromFields();
    if (c == null) {
      return;
    }
    final store = context.read<NotesStore>();
    store.saveCollection(c);
    store.selectCollection(c.id);
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    if (await confirmDelete() && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: Text(
      widget.collection == null ? 'New collection' : 'Collection settings',
    ),
    width: 460,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Clear of the field's floating label, which a dialog's title gap
        // would otherwise clip.
        const SizedBox(height: kSpaceXs),
        fields(context, onSubmit: _save),
        if (widget.collection != null) ...[
          const Divider(height: 40),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete collection'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
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
