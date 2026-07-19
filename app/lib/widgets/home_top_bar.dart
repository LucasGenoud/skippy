import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';

import '../screens/chat_screen.dart';
import '../screens/settings_screen.dart';
import '../state/auth_store.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';

/// The home screen's top bar: menu + branding, the search pill (with clear
/// and semantic-search controls), and the quick-settings icons + avatar menu.
/// Below 650px it collapses into a single Keep-style search pill.
class HomeTopBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool listMode;
  final bool semantic;
  final bool semanticAvailable;
  final bool semanticBusy;
  final ValueChanged<String> onQuery;
  final VoidCallback onToggleSemantic;
  final VoidCallback onToggleLayout;
  final VoidCallback onToggleSidebar;

  const HomeTopBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.listMode,
    required this.semantic,
    required this.semanticAvailable,
    required this.semanticBusy,
    required this.onQuery,
    required this.onToggleSemantic,
    required this.onToggleLayout,
    required this.onToggleSidebar,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNarrow = MediaQuery.sizeOf(context).width < 650;
    if (isNarrow) return _narrowBar(context, scheme);

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: scheme.surface,
      child: Row(
        children: [
          // ── Left: Menu + Logo + App Name ──
          IconButton(
            icon: const Icon(Icons.menu),
            tooltip: 'Main menu',
            onPressed: onToggleSidebar,
          ),
          const SizedBox(width: 4),
          Icon(Icons.sticky_note_2_rounded, color: scheme.primary, size: 28),
          const SizedBox(width: 10),
          Text(
            'Sticky Notes',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 16),

          // ── Center: Search Bar ──
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(kRadius),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      Icon(
                        Icons.search,
                        color: scheme.onSurfaceVariant,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          onChanged: onQuery,
                          textInputAction: TextInputAction.search,
                          style: Theme.of(context).textTheme.bodyLarge,
                          decoration: InputDecoration(
                            hintText: 'Search your notes',
                            hintStyle: TextStyle(
                              color: scheme.onSurfaceVariant,
                            ),
                            border: InputBorder.none,
                            isCollapsed: true,
                          ),
                        ),
                      ),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, _) => value.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                icon: const Icon(Icons.close, size: 20),
                                tooltip: 'Clear search',
                                onPressed: () {
                                  controller.clear();
                                  onQuery('');
                                },
                              ),
                      ),
                      if (semanticAvailable) _semanticControl(scheme),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),

          // ── Right: Quick Settings & User Avatar Circle ──
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Notes chat: only when the user configured an LLM (and the
              // server can do the retrieval side).
              if (context.watch<SettingsStore>().notesChatAvailable)
                IconButton(
                  icon: const Icon(Icons.forum_outlined),
                  tooltip: 'Chat with your notes',
                  onPressed: () => ChatScreen.open(context),
                ),
              const _SortButton(),
              IconButton(
                icon: Icon(
                  listMode
                      ? Icons.grid_view_outlined
                      : Icons.view_agenda_outlined,
                ),
                tooltip: listMode ? 'Grid view' : 'List view',
                onPressed: onToggleLayout,
              ),
              IconButton(
                icon: Icon(
                  Theme.of(context).brightness == Brightness.light
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                ),
                tooltip: Theme.of(context).brightness == Brightness.light
                    ? 'Dark theme'
                    : 'Light theme',
                onPressed: () => context.read<SettingsStore>().toggleTheme(
                  Theme.of(context).brightness,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () =>
                    Navigator.of(context).push(SettingsScreen.route()),
              ),
              const SizedBox(width: 6),
              const _UserAvatarMenu(),
              const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }

  /// The in-pill semantic-search control: a spinner while a search is in
  /// flight, otherwise the ✨ toggle.
  Widget _semanticControl(ColorScheme scheme) {
    if (semanticBusy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      icon: Icon(
        Icons.auto_awesome,
        size: 20,
        color: semantic ? scheme.primary : null,
      ),
      tooltip: semantic
          ? 'Semantic search on — results ranked by meaning'
          : 'Search by meaning',
      onPressed: onToggleSemantic,
    );
  }

  /// Phone layout, Keep-style: the whole bar is a single search pill. The
  /// drawer button, search field, and the few icons that matter on a phone
  /// (chat, layout, avatar) live inside it; while typing they give way to
  /// clear + semantic-search. Sort/theme/settings tuck into the avatar menu,
  /// and branding lives in the drawer.
  Widget _narrowBar(BuildContext context, ColorScheme scheme) {
    final chatAvailable = context.watch<SettingsStore>().notesChatAvailable;

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(kRadius),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Main menu',
              onPressed: onToggleSidebar,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onQuery,
                textInputAction: TextInputAction.search,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: 'Search your notes',
                  hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([controller, focusNode]),
              builder: (context, _) {
                final searching = controller.text.isNotEmpty;
                // Once the field is focused (or already holds a query), the
                // pill is in "search mode": show only the clear + semantic
                // controls, not the chat/layout/avatar shortcuts.
                if (focusNode.hasFocus || searching) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (searching)
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          tooltip: 'Clear search',
                          onPressed: () {
                            controller.clear();
                            onQuery('');
                          },
                        ),
                      if (semanticAvailable) _semanticControl(scheme),
                      const SizedBox(width: 4),
                    ],
                  );
                }
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (chatAvailable)
                      IconButton(
                        icon: const Icon(Icons.forum_outlined),
                        tooltip: 'Chat with your notes',
                        onPressed: () => ChatScreen.open(context),
                      ),
                    IconButton(
                      icon: Icon(
                        listMode
                            ? Icons.grid_view_outlined
                            : Icons.view_agenda_outlined,
                      ),
                      tooltip: listMode ? 'Grid view' : 'List view',
                      onPressed: onToggleLayout,
                    ),
                    const _UserAvatarMenu(),
                    const SizedBox(width: 6),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _UserAvatarMenu extends StatelessWidget {
  const _UserAvatarMenu();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final scheme = Theme.of(context).colorScheme;
    final username = auth.user?.username ?? '';
    final initial = username.isNotEmpty
        ? username.substring(0, 1).toUpperCase()
        : '?';

    return PopupMenuButton<String>(
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      tooltip: 'Google Account / User profile\n$username',
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      username,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      auth.activeUrl,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 20, color: scheme.onSurface),
              const SizedBox(width: 12),
              const Text('Settings'),
            ],
          ),
        ),
        if (MediaQuery.sizeOf(context).width < 650) ...[
          PopupMenuItem<String>(
            value: 'sort',
            child: Row(
              children: [
                Icon(Icons.swap_vert, size: 20, color: scheme.onSurface),
                const SizedBox(width: 12),
                const Text('Sort by'),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'theme',
            child: Row(
              children: [
                Icon(
                  Theme.of(context).brightness == Brightness.light
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                  size: 20,
                  color: scheme.onSurface,
                ),
                const SizedBox(width: 12),
                Text(
                  Theme.of(context).brightness == Brightness.light
                      ? 'Dark theme'
                      : 'Light theme',
                ),
              ],
            ),
          ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout, size: 20, color: scheme.error),
              const SizedBox(width: 12),
              Text('Sign out', style: TextStyle(color: scheme.error)),
            ],
          ),
        ),
      ],
      onSelected: (value) {
        if (value == 'settings') {
          Navigator.of(context).push(SettingsScreen.route());
        } else if (value == 'sort') {
          _showSortSheet(context);
        } else if (value == 'theme') {
          context.read<SettingsStore>().toggleTheme(
            Theme.of(context).brightness,
          );
        } else if (value == 'logout') {
          auth.signOut();
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: CircleAvatar(
          radius: 18,
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Text(
            initial,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
      ),
    );
  }
}

/// Sort control: Keep's "Sort by" options. Anything but custom order
/// disables drag-to-reorder (positions stay untouched).
const _sortModes = [
  (SortMode.custom, 'Custom order'),
  (SortMode.edited, 'Recently edited'),
  (SortMode.newest, 'Recently added'),
  (SortMode.oldest, 'Oldest first'),
];

class _SortButton extends StatelessWidget {
  const _SortButton();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    return PopupMenuButton<SortMode>(
      icon: const Icon(Icons.swap_vert),
      tooltip: 'Sort by',
      initialValue: store.sortMode,
      onSelected: store.setSortMode,
      itemBuilder: (context) => [
        for (final (mode, label) in _sortModes)
          CheckedPopupMenuItem(
            value: mode,
            checked: store.sortMode == mode,
            child: Text(label),
          ),
      ],
    );
  }
}

/// Phone counterpart of [_SortButton]: the same options as a bottom sheet,
/// reached from the avatar menu since the pill has no room for a sort icon.
void _showSortSheet(BuildContext context) {
  final store = context.read<NotesStore>();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (mode, label) in _sortModes)
            ListTile(
              leading: Icon(
                store.sortMode == mode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: store.sortMode == mode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(label),
              onTap: () {
                store.setSortMode(mode);
                Navigator.pop(context);
              },
            ),
        ],
      ),
    ),
  );
}
