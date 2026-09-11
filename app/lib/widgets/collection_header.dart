import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import 'collection_settings.dart';
import 'labels_sheet.dart';
import 'saved_view_dialog.dart';

enum _FilterAction { labels, smart }

class CollectionHeader extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;
  const CollectionHeader({
    super.key,
    required this.selection,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final c = store.activeCollection;
    final base = c?.layout == 'board'
        ? ViewSelection.board
        : ViewSelection.notes;
    final inset = MediaQuery.sizeOf(context).width >= 600 ? 32.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, kSpaceSm, inset, kSpaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  child: Tooltip(
                    message: c == null ? 'New collection' : 'Switch collection',
                    child: InkWell(
                      borderRadius: kBorderRadius,
                      onTap: () async {
                        final workspace = store.activeWorkspaceId;
                        if (workspace == null) {
                          return;
                        }
                        if (c == null) {
                          CollectionSettings.show(context);
                          return;
                        }
                        final id = await CollectionPicker.show(
                          context,
                          workspace,
                          selectedId: c.id,
                        );
                        if (id != null) {
                          store.selectCollection(id);
                          onSelect(
                            store.activeCollection?.layout == 'board'
                                ? ViewSelection.board
                                : ViewSelection.notes,
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: kSpaceMd),
                        child: Row(
                          children: [
                            Icon(
                              c?.icon == null
                                  ? Icons.folder_outlined
                                  : labelIconFor(c?.icon),
                              color: PaletteEntry.hexToColor(c?.color),
                              size: kCompactIconSize,
                            ),
                            const SizedBox(width: kSpaceSm),
                            Flexible(
                              child: Text(
                                c?.name ?? 'Create a collection',
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            const SizedBox(width: kSpaceXs),
                            const Icon(
                              Icons.expand_more,
                              size: kCompactIconSize,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (c != null)
                PopupMenuButton<Object>(
                  tooltip: 'Filter notes',
                  popUpAnimationStyle: Motion.menuFor(context),
                  icon: const Icon(Icons.filter_list, size: kCompactIconSize),
                  onSelected: (value) async {
                    if (value is ViewSelection) {
                      onSelect(value);
                      return;
                    }
                    await Motion.waitForMenuDismissal(context);
                    if (!context.mounted) {
                      return;
                    }
                    if (value == _FilterAction.labels) {
                      EditLabelsDialog.show(context);
                    } else {
                      EditSmartViewsDialog.show(context);
                    }
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: base,
                      checked: selection == base,
                      child: const Text('All notes in collection'),
                    ),
                    if (store.labels.isNotEmpty) const PopupMenuDivider(),
                    for (final label in store.labels)
                      CheckedPopupMenuItem(
                        value: ViewSelection(NoteView.label, label.id),
                        checked: selection.labelId == label.id,
                        child: Text(label.name),
                      ),
                    if (store.savedViews.isNotEmpty) const PopupMenuDivider(),
                    for (final view in store.savedViews)
                      CheckedPopupMenuItem(
                        value: ViewSelection.smart(view.id),
                        checked: selection.savedViewId == view.id,
                        child: Text(view.name),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _FilterAction.labels,
                      child: Text('Manage labels'),
                    ),
                    const PopupMenuItem(
                      value: _FilterAction.smart,
                      child: Text('Manage saved filters'),
                    ),
                  ],
                ),
              if (c != null)
                IconButton(
                  tooltip: 'Collection settings',
                  onPressed: () =>
                      CollectionSettings.show(context, collection: c),
                  icon: const Icon(Icons.more_horiz, size: kCompactIconSize),
                ),
            ],
          ),
          if (store.labels.isNotEmpty || selection.view == NoteView.smart)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final label in store.labels)
                    Padding(
                      padding: const EdgeInsets.only(right: kSpaceSm),
                      child: DragTarget<String>(
                        onAcceptWithDetails: (details) =>
                            store.addLabelToNote(details.data, label.id),
                        builder: (context, candidates, rejected) => FilterChip(
                          avatar: Icon(
                            labelIcon(label),
                            size: 16,
                            color: labelColorOrNull(label),
                          ),
                          label: Text(label.name),
                          showCheckmark: false,
                          selected:
                              selection.labelId == label.id ||
                              candidates.isNotEmpty,
                          onSelected: (selected) => onSelect(
                            selected
                                ? ViewSelection(NoteView.label, label.id)
                                : base,
                          ),
                        ),
                      ),
                    ),
                  if (selection.view == NoteView.smart)
                    InputChip(
                      avatar: const Icon(Icons.bookmark_outline, size: 16),
                      label: Text(
                        store.savedViewById(selection.savedViewId!)?.name ??
                            'Saved filter',
                      ),
                      selected: true,
                      onDeleted: () => onSelect(base),
                      deleteButtonTooltipMessage: 'Clear filter',
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
