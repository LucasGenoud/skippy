import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import '../util/platform.dart';
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

class AppSidebar extends StatefulWidget {
  final bool isOpen;
  final bool inDrawer;
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;
  final Set<String> selectedNoteIds;

  /// Called once a drop has filed the selection somewhere out of the view
  /// (archive, trash, another collection), so the screen can leave selection.
  final VoidCallback? onSelectionFiled;
  const AppSidebar({
    super.key,
    this.inDrawer = false,
    this.selectedNoteIds = const {},
    this.onSelectionFiled,
    required this.isOpen,
    required this.selection,
    required this.onSelect,
  });

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

/// Vertical inset of a row's highlight inside its slot: the row's own padding.
const double _rowInsetV = 1;
const double _rowInsetH = 12;

/// Where a section's selection wash sits, and how it got there.
typedef _Wash = ({double top, double height, bool shown, bool slides});

class _AppSidebarState extends State<AppSidebar> {
  // One wash per section (collections, labels, smart views, library) rather
  // than a fill per row: a new selection inside a section slides that
  // section's wash from the old row to the new one, while a section losing
  // its selection fades its wash where it stands. Rows are found by key after
  // layout; the washes sit under them in one Stack.
  final _stackKey = GlobalKey();
  final _rowKeys = <String, GlobalKey>{};
  Map<String, _Wash> _washes = const {};

  GlobalKey _rowKey(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  /// After this frame's layout, puts each section's wash under its selected
  /// row in [selected] (section to row id, null for none).
  void _placeWashes(Map<String, String?> selected) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final stack = _stackKey.currentContext?.findRenderObject();
      if (stack is! RenderBox) {
        return;
      }

      final next = <String, _Wash>{};
      for (final MapEntry(key: section, value: rowId) in selected.entries) {
        final was = _washes[section];
        final row = rowId == null
            ? null
            : _rowKeys[rowId]?.currentContext?.findRenderObject();
        if (row is! RenderBox || !row.attached) {
          if (was != null) {
            next[section] = (
              top: was.top,
              height: was.height,
              shown: false,
              slides: false,
            );
          }
          continue;
        }

        final top = row.localToGlobal(Offset.zero, ancestor: stack).dy;
        next[section] = (
          top: top + _rowInsetV,
          height: row.size.height - 2 * _rowInsetV,
          // Slide only from a row that was showing; appearing fresh, it lands.
          shown: true,
          slides: was != null && was.shown,
        );
      }

      if (_sameWashes(next, _washes)) {
        return;
      }
      setState(() => _washes = next);
    });
  }

  /// Equal where it shows: whether a wash slid to its place is history.
  bool _sameWashes(Map<String, _Wash> a, Map<String, _Wash> b) {
    if (a.length != b.length) {
      return false;
    }

    for (final MapEntry(:key, :value) in a.entries) {
      final other = b[key];
      if (other == null ||
          other.top != value.top ||
          other.height != value.height ||
          other.shown != value.shown) {
        return false;
      }
    }
    return true;
  }

  Future<void> _afterDrawer(
    BuildContext context,
    void Function(BuildContext context) show,
  ) async {
    final navigator = Navigator.of(context);
    if (widget.inDrawer) {
      navigator.pop();
      await Future<void>.delayed(Motion.slow);
      if (!navigator.mounted) return;
    }
    show(navigator.context);
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = widget.isOpen;
    final inDrawer = widget.inDrawer;
    final selection = widget.selection;
    final onSelect = widget.onSelect;
    final selectedNoteIds = widget.selectedNoteIds;
    final onSelectionFiled = widget.onSelectionFiled;
    final store = context.watch<NotesStore>();
    final scheme = Theme.of(context).colorScheme;
    final activeCollection = store.activeCollection;
    final baseSelection = activeCollection?.layout == 'board'
        ? ViewSelection.board
        : ViewSelection.notes;
    final collectionScopeVisible =
        selection.view != NoteView.archive &&
        selection.view != NoteView.trash &&
        selection.view != NoteView.reminders;
    Iterable<String> draggedIds(String id) =>
        selectedNoteIds.contains(id) ? selectedNoteIds : [id];
    bool acceptsAny(String id, bool Function(String) accepts) =>
        draggedIds(id).any(accepts);

    // The selected cards just left the view, so the bar acting on them has
    // nothing left to act on.
    void filed(String id) {
      if (selectedNoteIds.contains(id)) {
        onSelectionFiled?.call();
      }
    }

    const library = [
      (ViewSelection.reminders, Icons.notifications_outlined, 'Reminders'),
      (ViewSelection.archive, Icons.archive_outlined, 'Archive'),
      (ViewSelection.trash, Icons.delete_outline, 'Trash'),
    ];
    _placeWashes({
      'collections': activeCollection != null && collectionScopeVisible
          ? 'collection:${activeCollection.id}'
          : null,
      'labels': selection.labelId == null ? null : 'label:${selection.labelId}',
      'views': selection.savedViewId == null
          ? null
          : 'view:${selection.savedViewId}',
      'library': collectionScopeVisible
          ? null
          : 'library:${selection.view.name}',
    });

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: hairlineColor(scheme))),
      ),
      child: AnimatedContainer(
        duration: Motion.base,
        curve: Motion.emphasized,
        width: isOpen ? 268 : 72,
        child: ClipRect(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Stack(
                key: _stackKey,
                children: [
                  for (final MapEntry(:key, value: wash) in _washes.entries)
                    _SlidingHighlight(
                      key: ValueKey(key),
                      top: wash.top,
                      height: wash.height,
                      shown: wash.shown,
                      slides: wash.slides,
                    ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
                      const SizedBox(height: kSpaceLg),
                      _SidebarSectionHeader(
                        label: 'Collections',
                        isOpen: isOpen,
                      ),
                      for (final c in store.collections)
                        _SidebarItem(
                          key: _rowKey('collection:${c.id}'),
                          icon: c.icon == null
                              ? Icons.folder_outlined
                              : labelIconFor(c.icon),
                          selectedIcon: c.icon == null
                              ? Icons.folder
                              : filledLabelIconFor(c.icon),
                          iconColor: PaletteEntry.hexToColor(c.color),
                          label: c.name,
                          isOpen: isOpen,
                          isSelected:
                              activeCollection?.id == c.id &&
                              collectionScopeVisible,
                          onTap: () {
                            store.selectCollection(c.id);
                            onSelect(
                              c.layout == 'board'
                                  ? ViewSelection.board
                                  : ViewSelection.notes,
                            );
                          },
                          willAcceptNote: (id) => acceptsAny(
                            id,
                            (noteId) =>
                                store.noteById(noteId)?.workspaceId ==
                                c.workspaceId,
                          ),
                          onAcceptNote: (id) {
                            for (final noteId in draggedIds(id)) {
                              if (store.noteById(noteId)?.workspaceId ==
                                  c.workspaceId) {
                                store.restoreToCollection(noteId, c.id);
                              }
                            }
                            filed(id);
                          },
                        ),
                      _SidebarItem(
                        icon: Icons.edit_outlined,
                        selectedIcon: Icons.edit,
                        label: 'Manage collections',
                        isSelected: false,
                        isOpen: isOpen,
                        action: true,
                        onTap: () =>
                            _afterDrawer(context, ManageCollectionsDialog.show),
                      ),
                      const Divider(height: 32, indent: 16, endIndent: 16),
                      _SidebarSectionHeader(label: 'Labels', isOpen: isOpen),
                      for (final label in store.labels)
                        _SidebarItem(
                          key: _rowKey('label:${label.id}'),
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
                          willAcceptNote: (id) => acceptsAny(
                            id,
                            (noteId) => switch (store.noteById(noteId)) {
                              final note? =>
                                !note.trashed &&
                                    note.workspaceId == store.activeWorkspaceId,
                              null => false,
                            },
                          ),
                          onAcceptNote: (id) {
                            for (final noteId in draggedIds(id)) {
                              final note = store.noteById(noteId);
                              if (note != null &&
                                  !note.trashed &&
                                  note.workspaceId == store.activeWorkspaceId) {
                                store.addLabelToNote(noteId, label.id);
                              }
                            }
                          },
                        ),
                      _SidebarItem(
                        icon: Icons.edit_outlined,
                        selectedIcon: Icons.edit,
                        label: store.labels.isEmpty
                            ? 'Create labels'
                            : 'Manage labels',
                        isSelected: false,
                        isOpen: isOpen,
                        action: true,
                        onTap: () =>
                            _afterDrawer(context, EditLabelsDialog.show),
                      ),
                      const Divider(height: 24, indent: 16, endIndent: 16),
                      _SidebarSectionHeader(
                        label: 'Smart views',
                        isOpen: isOpen,
                      ),
                      for (final view in store.savedViews)
                        _SidebarItem(
                          key: _rowKey('view:${view.id}'),
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
                            ? 'Create a smart view'
                            : 'Manage smart views',
                        isSelected: false,
                        isOpen: isOpen,
                        action: true,
                        onTap: () =>
                            _afterDrawer(context, EditSmartViewsDialog.show),
                      ),
                      const Divider(height: 32, indent: 16, endIndent: 16),
                      _SidebarSectionHeader(label: 'Library', isOpen: isOpen),
                      for (final entry in library)
                        _SidebarItem(
                          key: _rowKey('library:${entry.$1.view.name}'),
                          icon: entry.$2,
                          selectedIcon: entry.$2,
                          label: entry.$3,
                          isSelected: selection == entry.$1,
                          isOpen: isOpen,
                          danger: entry.$1 == ViewSelection.trash,
                          onTap: () => onSelect(entry.$1),
                          // A note in Trash only leaves it by being filed in a
                          // collection, or through Restore.
                          willAcceptNote: (id) => acceptsAny(
                            id,
                            (noteId) =>
                                !(store.noteById(noteId)?.trashed ?? true) &&
                                (entry.$1 == ViewSelection.archive ||
                                    (entry.$1 == ViewSelection.trash &&
                                        store.canTrash(noteId))),
                          ),
                          onAcceptNote: entry.$1 == ViewSelection.reminders
                              ? null
                              : (id) {
                                  for (final noteId in draggedIds(id)) {
                                    if (store.noteById(noteId)?.trashed ??
                                        true) {
                                      continue;
                                    }
                                    if (entry.$1 == ViewSelection.archive) {
                                      store.setArchived(noteId, true);
                                    } else if (store.canTrash(noteId)) {
                                      store.moveToTrash(noteId);
                                    }
                                  }
                                  filed(id);
                                },
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
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
            style: sectionLabelStyle(Theme.of(context)),
          ),
        ),
      ),
    );
  }
}

const double _pointerRowHeight = 34;
const double _touchRowHeight = 44;
const double _iconSize = 18;

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isOpen;
  final bool action;

  /// A destructive destination (Trash): its drop highlight is red.
  final bool danger;
  final VoidCallback onTap;

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
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.isOpen,
    this.action = false,
    this.danger = false,
    required this.onTap,
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
    final dropForeground = danger
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    final Color foreground = dropTarget
        ? dropForeground
        : (action
              ? scheme.onSurfaceVariant.withValues(alpha: 0.72)
              : (isSelected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant));
    final Color labelColor = dropTarget
        ? dropForeground
        : (action
              ? scheme.onSurfaceVariant.withValues(alpha: 0.72)
              : (isSelected ? scheme.onSecondaryContainer : scheme.onSurface));
    // Compact rows for a pointer, a comfortable target for a finger. The icon
    // keeps its 48px column either way, which is the collapsed rail's width.
    final rowHeight = isTouchPrimaryPlatform
        ? _touchRowHeight
        : _pointerRowHeight;
    return Tooltip(
      message: isOpen ? '' : label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: _RowHighlight(
          dropTarget: dropTarget,
          danger: danger,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: kSmallBorderRadius,
              child: SizedBox(
                height: rowHeight,
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 48,
                  maxWidth: 244,
                  maxHeight: rowHeight,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        height: rowHeight,
                        child: Icon(
                          isSelected ? selectedIcon : icon,
                          size: _iconSize,
                          // A label's custom colour wins, except while it's a
                          // drop target (keep the highlight legible).
                          color: dropTarget
                              ? foreground
                              : (iconColor ?? foreground),
                        ),
                      ),
                      const SizedBox(width: kSpaceXs),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: labelColor,
                                fontWeight: isSelected
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                        ),
                      ),
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

/// A sidebar row's drop-target fill and border. What animates is the
/// *fraction*, not the colour: the endpoints are re-read from the live scheme
/// on every frame. Animating the colours directly (what AnimatedContainer
/// does) means chasing a target MaterialApp is already cross-fading, so a
/// light/dark switch left the sidebar visibly trailing the rest of the app,
/// the same reason [AppSidebar] paints its own fill. The selection is not
/// drawn here: each section's [_SlidingHighlight] carries it from row to row.
class _RowHighlight extends StatelessWidget {
  final bool dropTarget;
  final bool danger;
  final Widget child;

  const _RowHighlight({
    required this.dropTarget,
    this.danger = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const radius = kSmallBorderRadius;
    return _fade(dropTarget, (drop) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Color.lerp(
            Colors.transparent,
            danger ? scheme.errorContainer : scheme.primaryContainer,
            drop,
          ),
          borderRadius: radius,
          // Kept even at zero opacity: a border that appears only while
          // dragging would inset the row and shift its contents.
          border: Border.all(
            color: Color.lerp(
              Colors.transparent,
              danger ? scheme.error : scheme.primary,
              drop,
            )!,
            width: 1.5,
          ),
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      );
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

/// A section's selection wash: it slides from the old row to the new one
/// within its section, and fades where it stands when the section loses its
/// selection.
class _SlidingHighlight extends StatelessWidget {
  final double top;
  final double height;
  final bool shown;
  final bool slides;

  const _SlidingHighlight({
    super.key,
    required this.top,
    required this.height,
    required this.shown,
    required this.slides,
  });

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return AnimatedPositioned(
      duration: slides && !reduced ? Motion.base : Duration.zero,
      curve: Motion.emphasized,
      left: _rowInsetH,
      right: _rowInsetH,
      top: top,
      height: height,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: reduced ? Duration.zero : Motion.fast,
          curve: Motion.standard,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: kSmallBorderRadius,
            ),
          ),
        ),
      ),
    );
  }
}
