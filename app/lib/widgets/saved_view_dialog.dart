import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/saved_view.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/search_query.dart';
import 'drag_reorder_list.dart';
import 'form_dialog.dart';
import 'glyph_picker.dart';
import 'settings/accent_color.dart' show kAccentPresets;
import 'staggered_entrance.dart';

/// Create or edit a smart view: a name for the sidebar, the search it stands
/// for, and the glyph it wears. Deliberately the same shape as the label
/// editor, they are the two things that appear in the sidebar's lists.
class SavedViewDialog extends StatefulWidget {
  /// Null creates a new view.
  final String? savedViewId;

  /// Seeds the query field when creating, so "save this search" arrives with
  /// what the box already holds.
  final String initialQuery;

  const SavedViewDialog({super.key, this.savedViewId, this.initialQuery = ''});

  /// Returns the view that was created or edited, or null if the dialog was
  /// dismissed or the view deleted, so the caller can open what it saved.
  static Future<SavedView?> show(
    BuildContext context, {
    String? savedViewId,
    String initialQuery = '',
  }) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<SavedView>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: SavedViewDialog(
          savedViewId: savedViewId,
          initialQuery: initialQuery,
        ),
      ),
    );
  }

  @override
  State<SavedViewDialog> createState() => _SavedViewDialogState();
}

class _SavedViewDialogState extends State<SavedViewDialog> {
  late final TextEditingController _name;
  late final TextEditingController _query;
  String? _color;
  String? _icon;
  String? _nameError;
  String? _queryError;

  bool get _isNew => widget.savedViewId == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.savedViewId == null
        ? null
        : context.read<SettingsStore>().savedViewById(widget.savedViewId!);
    _name = TextEditingController(text: existing?.name ?? '');
    _query = TextEditingController(
      text: existing?.query ?? widget.initialQuery.trim(),
    );
    _color = existing?.color;
    _icon = existing?.icon;
  }

  @override
  void dispose() {
    _name.dispose();
    _query.dispose();
    super.dispose();
  }

  void _save() {
    final settings = context.read<SettingsStore>();
    final name = _name.text.trim();
    final query = _query.text.trim();
    final nameError = _nameProblem(settings, name);
    // An empty query would pin a view that just repeats the grid, and one made
    // only of unusable operators can never match, so neither is worth saving.
    final queryError = query.isEmpty
        ? 'Enter a search'
        : _operatorProblem(parseSearchQuery(query));
    if (nameError != null || queryError != null) {
      setState(() {
        _nameError = nameError;
        _queryError = queryError;
      });
      return;
    }
    final SavedView saved;
    if (_isNew) {
      saved = settings.addSavedView(
        name: name,
        query: query,
        icon: _icon,
        color: _color,
      );
    } else {
      settings.updateSavedView(
        widget.savedViewId!,
        name: name,
        query: query,
        icon: _icon,
        color: _color,
      );
      saved = settings.savedViewById(widget.savedViewId!)!;
    }
    Navigator.of(context).pop(saved);
  }

  String? _nameProblem(SettingsStore settings, String name) {
    if (name.isEmpty) return 'Enter a name';
    final clash = settings.savedViews.any(
      (v) =>
          v.id != widget.savedViewId &&
          v.name.toLowerCase() == name.toLowerCase(),
    );
    return clash ? 'A smart view named "$name" already exists' : null;
  }

  String? _operatorProblem(SearchQuery parsed) {
    final unknown = parsed.unknownFilters;
    if (unknown.isEmpty) return null;
    return 'No such filter: ${unknown.map((f) => f.toString()).join(', ')}';
  }

  Future<void> _delete() async {
    final settings = context.read<SettingsStore>();
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${_name.text.trim()}"?'),
        content: const Text(
          'The smart view goes away. The notes it showed are untouched.',
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
    if (confirmed != true) return;
    settings.removeSavedView(widget.savedViewId!);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FormDialog(
      title: Text(_isNew ? 'New smart view' : 'Edit smart view'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: _isNew,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _nameError,
            ),
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _query,
            decoration: InputDecoration(
              labelText: 'Search',
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: 'label:work is:pinned',
              helperText: 'Same filters as the search box',
              errorText: _queryError,
            ),
            onChanged: (_) {
              if (_queryError != null) setState(() => _queryError = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, 'Color'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ColorDot(
                color: null,
                selected: _color == null,
                onTap: () => setState(() => _color = null),
              ),
              for (final c in kAccentPresets)
                ColorDot(
                  color: c,
                  selected:
                      _color != null && PaletteEntry.hexToColor(_color) == c,
                  onTap: () =>
                      setState(() => _color = PaletteEntry.colorToHex(c)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, 'Icon'),
          const SizedBox(height: 10),
          IconGrid(
            selected: _icon,
            tint: PaletteEntry.hexToColor(_color) ?? scheme.onSurfaceVariant,
            onSelect: (key) => setState(() => _icon = key),
          ),
        ],
      ),
      actions: [
        if (!_isNew)
          TextButton(
            onPressed: _delete,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: Text(_isNew ? 'Save' : 'Done')),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// The list of smart views: create, reorder, edit, delete. Mirrors
/// [EditLabelsDialog] in `labels_sheet.dart`, the sidebar's other editable
/// list.
class EditSmartViewsDialog extends StatelessWidget {
  const EditSmartViewsDialog({super.key});

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<void>(
      context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: const EditSmartViewsDialog(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final views = settings.savedViews;
    final scheme = Theme.of(context).colorScheme;
    return FormDialog(
      title: const Text('Edit smart views'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.add),
            title: const Text('Create new smart view'),
            onTap: () => SavedViewDialog.show(context),
          ),
          const Divider(height: 8),
          DragReorderList<SavedView>(
            items: views,
            idOf: (view) => view.id,
            onReorder: (id, newIndex) => settings.reorderSavedViews(
              views.indexWhere((v) => v.id == id),
              newIndex,
            ),
            rowBuilder: (context, view, index, handle) => StaggeredEntrance(
              index: index,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    const SizedBox(width: 4),
                    Icon(
                      labelIconFor(view.icon),
                      color:
                          PaletteEntry.hexToColor(view.color) ??
                          scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                title: Text(view.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(view.query, overflow: TextOverflow.ellipsis),
                onTap: () =>
                    SavedViewDialog.show(context, savedViewId: view.id),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete smart view',
                  onPressed: () => settings.removeSavedView(view.id),
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
