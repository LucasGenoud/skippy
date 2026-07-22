import 'package:flutter/material.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'package:provider/provider.dart';

import '../screens/chat_screen.dart';
import '../screens/settings_screen.dart';
import '../state/auth_store.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/motion.dart';

({IconData icon, String label}) _nextThemeAction(ThemeMode current) =>
    switch (current) {
      ThemeMode.system => (
        icon: Icons.light_mode_outlined,
        label: 'Light theme',
      ),
      ThemeMode.light => (icon: Icons.dark_mode_outlined, label: 'Dark theme'),
      ThemeMode.dark => (
        icon: Icons.brightness_auto_outlined,
        label: 'System theme',
      ),
    };

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
    final settings = context.watch<SettingsStore>();
    final themeAction = _nextThemeAction(settings.themeMode);
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
          const AppLogo(size: 30),
          const SizedBox(width: 10),
          Text(
            'Skippy',
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
                child: _SearchPill(
                  focusNode: focusNode,
                  height: 46,
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
                        builder: (context, value, _) => _fadeScale(
                          child: value.text.isEmpty
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
              if (settings.notesChatAvailable)
                IconButton(
                  icon: const Icon(Icons.forum_outlined),
                  tooltip: 'Chat with your notes',
                  onPressed: () => ChatScreen.open(context),
                ),
              const _RefreshButton(),
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
                // The sun/moon rotates in as the theme flips — a nod to the
                // day/night metaphor without slowing the switch down.
                icon: AnimatedSwitcher(
                  duration: Motion.base,
                  switchInCurve: Motion.standard,
                  transitionBuilder: (child, animation) => RotationTransition(
                    turns: Tween<double>(
                      begin: 0.85,
                      end: 1,
                    ).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Icon(
                    themeAction.icon,
                    key: ValueKey(settings.themeMode),
                  ),
                ),
                tooltip: themeAction.label,
                onPressed: settings.cycleThemeMode,
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
  /// flight, otherwise the ✨ toggle. The two cross-fade instead of popping.
  Widget _semanticControl(ColorScheme scheme) {
    return _fadeScale(
      child: semanticBusy
          ? const Padding(
              key: ValueKey('busy'),
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : IconButton(
              key: const ValueKey('toggle'),
              icon: Icon(
                Icons.auto_awesome,
                size: 20,
                color: semantic ? scheme.primary : null,
              ),
              tooltip: semantic
                  ? 'Semantic search on — results ranked by meaning'
                  : 'Search by meaning',
              onPressed: onToggleSemantic,
            ),
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
      child: _SearchPill(
        focusNode: focusNode,
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
                // controls, not the chat/layout/avatar shortcuts. The two
                // control sets cross-fade rather than hard-swapping.
                final Widget controls;
                if (focusNode.hasFocus || searching) {
                  controls = Row(
                    key: const ValueKey('search-mode'),
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
                } else {
                  controls = Row(
                    key: const ValueKey('idle-mode'),
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
                }
                return _fadeScale(child: controls);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Fade + scale between two states of a small control; the standard
/// transition for icons that appear, disappear, or swap inside the bar.
Widget _fadeScale({required Widget child}) {
  return AnimatedSwitcher(
    duration: Motion.fast,
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: animation, child: child),
    ),
    child: child,
  );
}

/// The search pill's chrome. At rest it sits flush in the bar; when the field
/// gains focus it lifts — surface fill plus a soft shadow — so the active
/// search state is unmistakable (Keep's focused-search treatment).
class _SearchPill extends StatelessWidget {
  final FocusNode focusNode;
  final double? height;
  final Widget child;
  const _SearchPill({
    required this.focusNode,
    this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, child) {
        final focused = focusNode.hasFocus;
        return AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          height: height,
          decoration: BoxDecoration(
            // In light mode the lifted pill goes white-on-white with the bar,
            // so the shadow does the separating; dark mode lifts by lightness.
            color: focused
                ? (light ? scheme.surface : scheme.surfaceContainerHighest)
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(
              color: focused ? scheme.outlineVariant : Colors.transparent,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: focused ? 0.10 : 0),
                blurRadius: focused ? 10 : 0,
                offset: Offset(0, focused ? 2 : 0),
              ),
            ],
          ),
          child: child,
        );
      },
      child: child,
    );
  }
}

class _UserAvatarMenu extends StatelessWidget {
  const _UserAvatarMenu();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final settings = context.watch<SettingsStore>();
    final scheme = Theme.of(context).colorScheme;
    final name = auth.user?.name ?? '';
    final initial = name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?';
    final syncStatus = context.select<NotesStore, SyncStatus>(
      (s) => s.syncStatus,
    );
    final themeAction = _nextThemeAction(settings.themeMode);

    return PopupMenuButton<String>(
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
      ),
      tooltip: name,
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
                      name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      auth.user?.email ?? auth.activeUrl,
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
                Icon(themeAction.icon, size: 20, color: scheme.onSurface),
                const SizedBox(width: 12),
                Text(themeAction.label),
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
          settings.cycleThemeMode();
        } else if (value == 'logout') {
          auth.signOut();
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Stack(
          clipBehavior: Clip.none,
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
            Positioned(
              right: -2,
              bottom: -2,
              child: _SyncBadge(status: syncStatus),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small connectivity/sync indicator overlaid on the avatar: offline (no
/// server), syncing (unsynced local edits in flight, animated), or synced
/// (all changes saved). Ringed with the bar colour so it reads over the avatar.
class _SyncBadge extends StatefulWidget {
  final SyncStatus status;
  const _SyncBadge({required this.status});

  @override
  State<_SyncBadge> createState() => _SyncBadgeState();
}

class _SyncBadgeState extends State<_SyncBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(_SyncBadge old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _syncSpin();
  }

  void _syncSpin() {
    if (widget.status == SyncStatus.syncing) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String tip) = switch (widget.status) {
      SyncStatus.offline => (
        Icons.cloud_off_rounded,
        scheme.error,
        'Offline — changes will sync when you reconnect',
      ),
      SyncStatus.syncing => (
        Icons.sync_rounded,
        scheme.primary,
        'Syncing changes…',
      ),
      SyncStatus.synced => (
        Icons.cloud_done_rounded,
        // A calm green that reads the same in light and dark.
        const Color(0xFF34A853),
        'All changes saved',
      ),
    };
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Ring in the bar's colour so the badge separates from the avatar.
          color: scheme.surface,
        ),
        child: RotationTransition(
          turns: _spin,
          child: Icon(icon, size: 13, color: color),
        ),
      ),
    );
  }
}

/// Desktop-only manual refresh: re-pulls notes/labels from the server (mobile
/// relies on the live WebSocket). Shows a spinner while the pull is in flight.
class _RefreshButton extends StatelessWidget {
  const _RefreshButton();

  @override
  Widget build(BuildContext context) {
    final refreshing = context.select<NotesStore, bool>((s) => s.refreshing);
    return IconButton(
      icon: refreshing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      tooltip: 'Refresh',
      onPressed: refreshing ? null : () => context.read<NotesStore>().refresh(),
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
