import 'package:flutter/material.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'labels_sheet.dart';
import 'workspace_menu.dart';

class AppDrawer extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;

  const AppDrawer({super.key, required this.selection, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final labels = store.labels;

    final destinations = <(ViewSelection, NavigationDrawerDestination)>[
      (
        ViewSelection.notes,
        const NavigationDrawerDestination(
          icon: Icon(Icons.lightbulb_outline),
          selectedIcon: Icon(Icons.lightbulb),
          label: Text('Notes'),
        ),
      ),
      (
        ViewSelection.reminders,
        const NavigationDrawerDestination(
          icon: Icon(Icons.notifications_outlined),
          selectedIcon: Icon(Icons.notifications),
          label: Text('Reminders'),
        ),
      ),
      for (final label in labels)
        (
          ViewSelection(NoteView.label, label.id),
          NavigationDrawerDestination(
            // The label's icon + colour (matching its chips). A null colour
            // falls back to the drawer's selection-aware theming; the default
            // (no custom icon) keeps the outline/filled pair.
            icon: Icon(
              label.icon != null ? labelIcon(label) : Icons.label_outline,
              color: labelColorOrNull(label),
            ),
            selectedIcon: Icon(
              label.icon != null ? labelIcon(label) : Icons.label,
              color: labelColorOrNull(label),
            ),
            label: Text(label.name, overflow: TextOverflow.ellipsis),
          ),
        ),
      (
        ViewSelection.archive,
        const NavigationDrawerDestination(
          icon: Icon(Icons.archive_outlined),
          selectedIcon: Icon(Icons.archive),
          label: Text('Archive'),
        ),
      ),
      (
        ViewSelection.trash,
        const NavigationDrawerDestination(
          icon: Icon(Icons.delete_outline),
          selectedIcon: Icon(Icons.delete),
          label: Text('Trash'),
        ),
      ),
    ];

    final selectedIndex = destinations.indexWhere((d) => d.$1 == selection);

    return NavigationDrawer(
      selectedIndex: selectedIndex < 0 ? null : selectedIndex,
      onDestinationSelected: (index) {
        Navigator.of(context).pop();
        onSelect(destinations[index].$1);
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 16, 12),
          child: Row(
            children: [
              const AppLogo(size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Skippy',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          // The switcher brings its own horizontal inset (it draws a card, and
          // that card lines up with the destination pills below).
          padding: const EdgeInsets.only(bottom: 8),
          // The drawer route sits above dialogs, so close it before the menu
          // opens one.
          child: WorkspaceMenu(
            onBeforeAction: () => Navigator.of(context).pop(),
          ),
        ),
        destinations[0].$2,
        destinations[1].$2,
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 12, 28, 8),
          child: Divider(height: 1),
        ),
        if (labels.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
            child: Text(
              'Labels',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (var i = 2; i < destinations.length - 2; i++) destinations[i].$2,
        InkWell(
          onTap: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            EditLabelsDialog.show(navigator.context);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.edit_outlined,
                  size: 22,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 14),
                Text(
                  labels.isEmpty ? 'Create labels' : 'Edit labels',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 8, 28, 12),
          child: Divider(height: 1),
        ),
        destinations[destinations.length - 2].$2,
        destinations[destinations.length - 1].$2,
        const SizedBox(height: 16),
      ],
    );
  }
}

class AppSidebar extends StatelessWidget {
  final bool isOpen;
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;

  const AppSidebar({
    super.key,
    required this.isOpen,
    required this.selection,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final labels = store.labels;
    final scheme = Theme.of(context).colorScheme;

    // Only the width is implicitly animated. Handing the fill to
    // AnimatedContainer too made light/dark switches visibly drag: the theme
    // itself cross-fades over kThemeAnimationDuration, so the target colour
    // moves every frame and the container keeps restarting a 250ms tween
    // toward it — the rail finished long after the rest of the app. Painted
    // straight from the scheme, it lands exactly with everything else.
    //
    // The trailing seam matches the drawer's on narrow layouts and the top
    // bar's underline. DecoratedBox, not Container: a bordered Container
    // insets its child, which would fight the width animation.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: hairlineColor(scheme))),
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
        width: isOpen ? 268 : 72,
        child: ClipRect(
          child: ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 24),
            children: [
              WorkspaceMenu(compact: !isOpen),
              // No divider: the switcher's own border already separates it
              // from the views below.
              const SizedBox(height: 8),
              _SidebarItem(
                icon: Icons.lightbulb_outline,
                selectedIcon: Icons.lightbulb,
                label: 'Notes',
                isSelected: selection == ViewSelection.notes,
                isOpen: isOpen,
                onTap: () => onSelect(ViewSelection.notes),
              ),
              _SidebarItem(
                icon: Icons.view_kanban_outlined,
                selectedIcon: Icons.view_kanban,
                label: 'Board',
                isSelected: selection == ViewSelection.board,
                isOpen: isOpen,
                onTap: () => onSelect(ViewSelection.board),
              ),
              _SidebarItem(
                icon: Icons.notifications_outlined,
                selectedIcon: Icons.notifications,
                label: 'Reminders',
                isSelected: selection == ViewSelection.reminders,
                isOpen: isOpen,
                onTap: () => onSelect(ViewSelection.reminders),
              ),
              if (labels.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(height: 1, indent: 16, endIndent: 16),
                ),
                // Constant-height slot: the header fades with the rail's
                // width animation instead of vanishing and jumping the
                // label items up.
                SizedBox(
                  height: 28,
                  child: AnimatedOpacity(
                    opacity: isOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOutCubic,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 6, 28, 6),
                      child: Text(
                        'LABELS',
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
                ),
                for (final label in labels)
                  _SidebarItem(
                    // Reuse the label's own icon + colour (matching its chips);
                    // a custom icon has no filled variant so it's used for both
                    // states, while the default keeps the outline/filled pair.
                    icon: label.icon != null
                        ? labelIcon(label)
                        : Icons.label_outline,
                    selectedIcon: label.icon != null
                        ? labelIcon(label)
                        : Icons.label,
                    iconColor: labelColorOrNull(label),
                    label: label.name,
                    isSelected:
                        selection == ViewSelection(NoteView.label, label.id),
                    isOpen: isOpen,
                    onTap: () =>
                        onSelect(ViewSelection(NoteView.label, label.id)),
                    onAcceptNote: (noteId) =>
                        _dropOnLabel(context, noteId, label),
                  ),
              ],
              _SidebarItem(
                icon: Icons.edit_outlined,
                selectedIcon: Icons.edit,
                label: labels.isEmpty ? 'Create labels' : 'Edit labels',
                isSelected: false,
                isOpen: isOpen,
                onTap: () => EditLabelsDialog.show(context),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(height: 1, indent: 16, endIndent: 16),
              ),
              _SidebarItem(
                icon: Icons.archive_outlined,
                selectedIcon: Icons.archive,
                label: 'Archive',
                isSelected: selection == ViewSelection.archive,
                isOpen: isOpen,
                onTap: () => onSelect(ViewSelection.archive),
                onAcceptNote: (noteId) => _dropOnArchive(context, noteId),
              ),
              _SidebarItem(
                icon: Icons.delete_outline,
                selectedIcon: Icons.delete,
                label: 'Trash',
                isSelected: selection == ViewSelection.trash,
                isOpen: isOpen,
                onTap: () => onSelect(ViewSelection.trash),
                onAcceptNote: (noteId) => _dropOnTrash(context, noteId),
                willAcceptNote: (noteId) =>
                    context.read<NotesStore>().canTrash(noteId),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _dropOnLabel(BuildContext context, String noteId, Label label) {
    final store = context.read<NotesStore>();
    if (store.addLabelToNote(noteId, label.id)) {
      showAppSnack('Labelled "${label.name}"', icon: labelIcon(label));
    } else {
      showAppSnack('Already labelled "${label.name}"', icon: labelIcon(label));
    }
  }

  void _dropOnArchive(BuildContext context, String noteId) {
    final store = context.read<NotesStore>();
    final note = store.noteById(noteId);
    if (note == null || note.archived) return;
    store.setArchived(noteId, true);
    showAppSnack(
      'Note archived',
      icon: Icons.archive_outlined,
      actionLabel: 'Undo',
      onAction: () => store.setArchived(noteId, false),
    );
  }

  void _dropOnTrash(BuildContext context, String noteId) {
    final store = context.read<NotesStore>();
    if (!store.canTrash(noteId)) return;
    store.moveToTrash(noteId);
    showAppSnack(
      'Note moved to trash',
      icon: Icons.delete_outline,
      kind: SnackKind.danger,
      actionLabel: 'Undo',
      onAction: () => store.restoreFromTrash(noteId),
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

  /// Overrides the icon's colour (a label's custom colour). Null keeps the
  /// selection-aware default. Ignored while the item is an active drop target,
  /// so the drop highlight stays unambiguous.
  final Color? iconColor;

  /// When set, the item becomes a drop target for a note dragged from the
  /// grid (the masonry drag carries the note id as `Draggable<String>` data).
  final ValueChanged<String>? onAcceptNote;

  /// Optional gate — a dragged note is only accepted when this returns true
  /// (e.g. Trash refuses notes you don't own).
  final bool Function(String noteId)? willAcceptNote;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.isOpen,
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
                          size: 24,
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
/// rest of the app — the same reason [AppSidebar] paints its own fill.
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
