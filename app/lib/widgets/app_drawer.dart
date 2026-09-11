import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/collection.dart';
import '../theme.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import 'collection_settings.dart';
import 'labels_sheet.dart';
import 'saved_view_dialog.dart';
import 'workspace_menu.dart';

class AppDrawer extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;
  const AppDrawer({super.key, required this.selection, required this.onSelect});
  @override
  Widget build(BuildContext context) => Drawer(
    child: SafeArea(
      child: AppSidebar(
        inDrawer: true,
        isOpen: true,
        selection: selection,
        onSelect: (v) {
          Navigator.pop(context);
          onSelect(v);
        },
      ),
    ),
  );
}

class AppSidebar extends StatelessWidget {
  final bool isOpen;
  final bool inDrawer;
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;
  const AppSidebar({
    super.key,
    this.inDrawer = false,
    required this.isOpen,
    required this.selection,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final scheme = Theme.of(context).colorScheme;
    final activeCollection = store.activeCollection;
    final baseSelection = activeCollection?.layout == 'board'
        ? ViewSelection.board
        : ViewSelection.notes;

    Future<void> showCollectionSettings([NoteCollection? collection]) async {
      final navigator = Navigator.of(context);
      if (inDrawer) {
        navigator.pop();
        await Future<void>.delayed(Motion.slow);
        if (!navigator.mounted) return;
      }
      CollectionSettings.show(navigator.context, collection: collection);
    }

    Future<void> showLabels() async {
      final navigator = Navigator.of(context);
      if (inDrawer) {
        navigator.pop();
        await Future<void>.delayed(Motion.slow);
        if (!navigator.mounted) return;
      }
      EditLabelsDialog.show(navigator.context);
    }

    Future<void> showSavedFilters() async {
      final navigator = Navigator.of(context);
      if (inDrawer) {
        navigator.pop();
        await Future<void>.delayed(Motion.slow);
        if (!navigator.mounted) return;
      }
      EditSmartViewsDialog.show(navigator.context);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: hairlineColor(scheme))),
      ),
      child: AnimatedContainer(
        duration: Motion.base,
        width: isOpen ? 268 : 72,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            WorkspaceMenu(
              compact: !isOpen,
              onBeforeAction: !inDrawer
                  ? null
                  : () async {
                      Navigator.of(context).pop();
                      await Future<void>.delayed(Motion.slow);
                    },
            ),
            const SizedBox(height: 16),
            _SidebarSectionHeader(label: 'COLLECTIONS', isOpen: isOpen),
            for (final c in store.collections)
              _SidebarItem(
                icon: c.icon == null
                    ? Icons.folder_outlined
                    : labelIconFor(c.icon),
                selectedIcon: c.icon == null
                    ? Icons.folder
                    : labelIconFor(c.icon),
                iconColor: PaletteEntry.hexToColor(c.color),
                label: c.name,
                isOpen: isOpen,
                isSelected:
                    store.activeCollection?.id == c.id &&
                    ![
                      NoteView.archive,
                      NoteView.trash,
                      NoteView.reminders,
                    ].contains(selection.view),
                onTap: () {
                  store.selectCollection(c.id);
                  onSelect(
                    c.layout == 'board'
                        ? ViewSelection.board
                        : ViewSelection.notes,
                  );
                },
                trailing: store.activeCollection?.id == c.id
                    ? IconButton(
                        tooltip: 'Collection settings',
                        icon: const Icon(Icons.more_horiz, size: 20),
                        onPressed: () => showCollectionSettings(c),
                      )
                    : null,
                willAcceptNote: (id) =>
                    store.noteById(id)?.workspaceId == c.workspaceId,
                onAcceptNote: (id) => store.moveToCollection(id, c.id),
              ),
            _SidebarItem(
              icon: Icons.add,
              selectedIcon: Icons.add,
              label: 'New collection',
              isSelected: false,
              isOpen: isOpen,
              onTap: showCollectionSettings,
            ),
            const Divider(height: 32, indent: 16, endIndent: 16),
            _SidebarSectionHeader(label: 'LABELS', isOpen: isOpen),
            for (final label in store.labels)
              _SidebarItem(
                icon: label.icon == null
                    ? Icons.label_outline
                    : labelIcon(label),
                selectedIcon: label.icon == null
                    ? Icons.label
                    : labelIcon(label),
                iconColor: labelColorOrNull(label),
                label: label.name,
                isSelected: selection.labelId == label.id,
                isOpen: isOpen,
                onTap: () => onSelect(
                  selection.labelId == label.id
                      ? baseSelection
                      : ViewSelection(NoteView.label, label.id),
                ),
                willAcceptNote: (id) =>
                    store.noteById(id)?.workspaceId == store.activeWorkspaceId,
                onAcceptNote: (id) => store.addLabelToNote(id, label.id),
              ),
            _SidebarItem(
              icon: Icons.edit_outlined,
              selectedIcon: Icons.edit,
              label: store.labels.isEmpty ? 'Create labels' : 'Manage labels',
              isSelected: false,
              isOpen: isOpen,
              onTap: showLabels,
            ),
            const Divider(height: 24, indent: 16, endIndent: 16),
            _SidebarSectionHeader(label: 'SAVED FILTERS', isOpen: isOpen),
            for (final view in store.savedViews)
              _SidebarItem(
                icon: view.icon == null
                    ? Icons.bookmark_outline
                    : labelIconFor(view.icon),
                selectedIcon: view.icon == null
                    ? Icons.bookmark
                    : labelIconFor(view.icon),
                iconColor: PaletteEntry.hexToColor(view.color),
                label: view.name,
                isSelected: selection.savedViewId == view.id,
                isOpen: isOpen,
                onTap: () => onSelect(
                  selection.savedViewId == view.id
                      ? baseSelection
                      : ViewSelection.smart(view.id),
                ),
              ),
            _SidebarItem(
              icon: Icons.edit_outlined,
              selectedIcon: Icons.edit,
              label: store.savedViews.isEmpty
                  ? 'Create saved filter'
                  : 'Manage saved filters',
              isSelected: false,
              isOpen: isOpen,
              onTap: showSavedFilters,
            ),
            const Divider(height: 32, indent: 16, endIndent: 16),
            for (final entry in [
              (
                ViewSelection.reminders,
                Icons.notifications_outlined,
                'Reminders',
              ),
              (ViewSelection.archive, Icons.archive_outlined, 'Archive'),
              (ViewSelection.trash, Icons.delete_outline, 'Trash'),
            ])
              _SidebarItem(
                icon: entry.$2,
                selectedIcon: entry.$2,
                label: entry.$3,
                isSelected: selection == entry.$1,
                isOpen: isOpen,
                onTap: () => onSelect(entry.$1),
                willAcceptNote: (id) =>
                    entry.$1 == ViewSelection.archive ||
                    (entry.$1 == ViewSelection.trash && store.canTrash(id)),
                onAcceptNote: entry.$1 == ViewSelection.reminders
                    ? null
                    : (id) {
                        if (entry.$1 == ViewSelection.archive) {
                          store.setArchived(id, true);
                        } else {
                          store.moveToTrash(id);
                        }
                      },
              ),
          ],
        ),
      ),
    );
  }
}

class _SidebarSectionHeader extends StatelessWidget {
  final String label;
  final bool isOpen;
  const _SidebarSectionHeader({required this.label, required this.isOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 28,
      child: AnimatedOpacity(
        opacity: isOpen ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 6),
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isOpen;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Overrides the icon's colour (a label's custom colour). Null keeps the
  /// selection-aware default. Ignored while the item is an active drop target,
  /// so the drop highlight stays unambiguous.
  final Color? iconColor;

  /// When set, the item becomes a drop target for a note dragged from the
  /// grid (the masonry drag carries the note id as `Draggable<String>` data).
  final ValueChanged<String>? onAcceptNote;

  /// Optional gate, a dragged note is only accepted when this returns true
  /// (e.g. Trash refuses notes you don't own).
  final bool Function(String noteId)? willAcceptNote;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.isOpen,
    required this.onTap,
    this.trailing,
    this.iconColor,
    this.onAcceptNote,
    this.willAcceptNote,
  });

  @override
  Widget build(BuildContext context) {
    final item = _buildItem(context, dropTarget: false);
    if (onAcceptNote == null) return item;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          willAcceptNote?.call(details.data) ?? true,
      onAcceptWithDetails: (details) => onAcceptNote!(details.data),
      builder: (context, candidate, rejected) =>
          _buildItem(context, dropTarget: candidate.isNotEmpty),
    );
  }

  Widget _buildItem(BuildContext context, {required bool dropTarget}) {
    final scheme = Theme.of(context).colorScheme;
    final Color foreground = dropTarget
        ? scheme.onPrimaryContainer
        : (isSelected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant);
    final Color labelColor = dropTarget
        ? scheme.onPrimaryContainer
        : (isSelected ? scheme.onSecondaryContainer : scheme.onSurface);
    return Tooltip(
      message: isOpen ? '' : label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: _RowHighlight(
          selected: isSelected,
          dropTarget: dropTarget,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(kRadius),
              child: SizedBox(
                height: 48,
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 48,
                  maxWidth: 244,
                  maxHeight: 48,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          isSelected ? selectedIcon : icon,
                          size: kStandardIconSize,
                          // A label's custom colour wins, except while it's a
                          // drop target (keep the highlight legible).
                          color: dropTarget
                              ? foreground
                              : (iconColor ?? foreground),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: labelColor,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                        ),
                      ),
                      if (isOpen && trailing != null)
                        SizedBox(width: 44, height: 44, child: trailing),
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
}

/// A sidebar row's fill and border. Selection and drop-target both fade, but
/// what animates is the *fraction*, not the colour: the endpoints are re-read
/// from the live scheme on every frame. Animating the colours directly (what
/// AnimatedContainer does) means chasing a target MaterialApp is already
/// cross-fading, so a light/dark switch left the sidebar visibly trailing the
/// rest of the app, the same reason [AppSidebar] paints its own fill.
class _RowHighlight extends StatelessWidget {
  final bool selected;
  final bool dropTarget;
  final Widget child;

  const _RowHighlight({
    required this.selected,
    required this.dropTarget,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(kRadius);
    return _fade(dropTarget, (drop) {
      return _fade(selected, (sel) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Color.lerp(
              Color.lerp(Colors.transparent, scheme.secondaryContainer, sel),
              scheme.primaryContainer,
              drop,
            ),
            borderRadius: radius,
            // Kept even at zero opacity: a border that appears only while
            // dragging would inset the row and shift its contents.
            border: Border.all(
              color: Color.lerp(Colors.transparent, scheme.primary, drop)!,
              width: 1.5,
            ),
          ),
          child: ClipRRect(borderRadius: radius, child: child),
        );
      });
    });
  }

  /// Hands [builder] an animated 0→1 stand-in for [on].
  Widget _fade(bool on, Widget Function(double t) builder) {
    final target = on ? 1.0 : 0.0;
    return TweenAnimationBuilder<double>(
      // begin == end: the fraction only ever moves because `end` changed, so
      // a row that starts out selected doesn't fade in on first build.
      tween: Tween<double>(begin: target, end: target),
      duration: Motion.fast,
      curve: Motion.standard,
      builder: (context, t, _) => builder(t),
    );
  }
}
