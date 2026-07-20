import 'package:flutter/material.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';
import 'labels_sheet.dart';

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
            icon: const Icon(Icons.label_outline),
            selectedIcon: const Icon(Icons.label),
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

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOutCubic,
      width: isOpen ? 268 : 72,
      color: scheme.surface,
      child: ClipRect(
        child: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          children: [
            _SidebarItem(
              icon: Icons.lightbulb_outline,
              selectedIcon: Icons.lightbulb,
              label: 'Notes',
              isSelected: selection == ViewSelection.notes,
              isOpen: isOpen,
              onTap: () => onSelect(ViewSelection.notes),
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
                  duration: const Duration(milliseconds: 260),
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
                  icon: Icons.label_outline,
                  selectedIcon: Icons.label,
                  label: label.name,
                  isSelected:
                      selection == ViewSelection(NoteView.label, label.id),
                  isOpen: isOpen,
                  onTap: () =>
                      onSelect(ViewSelection(NoteView.label, label.id)),
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
            ),
            _SidebarItem(
              icon: Icons.delete_outline,
              selectedIcon: Icons.delete,
              label: 'Trash',
              isSelected: selection == ViewSelection.trash,
              isOpen: isOpen,
              onTap: () => onSelect(ViewSelection.trash),
            ),
          ],
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

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.isOpen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: isOpen ? '' : label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Material(
          color: isSelected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadius),
          clipBehavior: Clip.antiAlias,
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
                        color: isSelected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: isSelected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurface,
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
    );
  }
}
