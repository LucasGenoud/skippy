import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/settings_screen.dart';
import '../state/auth_store.dart';
import '../state/notes_store.dart';
import 'labels_sheet.dart';

class AppDrawer extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;

  const AppDrawer({super.key, required this.selection, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final auth = context.watch<AuthStore>();
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
              Icon(
                Icons.sticky_note_2_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Sticky Notes',
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
        // "Edit labels" sits with the label list but is an action, not a view.
        InkWell(
          onTap: () {
            // The drawer's own context dies when it pops; use the navigator's.
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
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 12, 28, 8),
          child: Divider(height: 1),
        ),
        InkWell(
          onTap: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            navigator.push(SettingsScreen.route());
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.settings_outlined,
                  size: 22,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 14),
                Text('Settings', style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
          ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 28),
          leading: CircleAvatar(
            radius: 14,
            child: Text(
              (auth.user?.username ?? '?').substring(0, 1).toUpperCase(),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          title: Text(auth.user?.username ?? ''),
          trailing: IconButton(
            icon: const Icon(Icons.logout, size: 20),
            tooltip: 'Sign out',
            onPressed: () {
              Navigator.of(context).pop();
              auth.signOut();
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
