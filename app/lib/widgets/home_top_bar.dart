import 'dart:math' as math;

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

/// The top bar displays the active setting, matching Settings → Appearance.
/// Tapping still cycles to the next choice.
({IconData icon, String label}) _currentThemeAction(ThemeMode current) =>
    switch (current) {
      ThemeMode.system => (icon: Icons.brightness_auto_outlined, label: 'Auto'),
      ThemeMode.light => (icon: Icons.light_mode_outlined, label: 'Light'),
      ThemeMode.dark => (icon: Icons.dark_mode_outlined, label: 'Dark'),
    };

enum _SelectionAction { stage, label, share, color, pin }

/// The home screen's top bar: menu + branding, the search pill (with clear
/// and semantic-search controls), and the quick-settings icons + avatar menu.
/// Below 650px it collapses into a single search pill.
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
  final bool selectionMode;
  final int selectedCount;
  final bool allSelected;
  final bool canArchive;
  final bool archiveSelected;
  final bool pinSelected;
  final bool canRestore;
  final bool canTrash;
  final VoidCallback onCancelSelection;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onArchiveSelected;
  final VoidCallback onRestoreSelected;
  final VoidCallback onTrashSelected;
  final VoidCallback onAddLabelSelected;

  /// Bulk-file the selection into a board column. Only offered on the board,
  /// where columns are the thing on screen.
  final VoidCallback onMoveToStageSelected;
  final bool canMoveToStage;
  final VoidCallback onSetColorSelected;
  final VoidCallback onPinSelected;
  final VoidCallback onShareSelected;

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
    required this.selectionMode,
    required this.selectedCount,
    required this.allSelected,
    required this.canArchive,
    required this.archiveSelected,
    required this.pinSelected,
    required this.canRestore,
    required this.canTrash,
    required this.onCancelSelection,
    required this.onToggleSelectAll,
    required this.onArchiveSelected,
    required this.onRestoreSelected,
    required this.onTrashSelected,
    required this.onAddLabelSelected,
    required this.onMoveToStageSelected,
    required this.canMoveToStage,
    required this.onSetColorSelected,
    required this.onPinSelected,
    required this.onShareSelected,
  });

  /// The bar's own height, and the search pill inside it.
  static const double barHeight = 58;
  static const double _pillHeight = 40;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (selectionMode) return _selectionBar(context, scheme);
    final settings = context.watch<SettingsStore>();
    final themeAction = _currentThemeAction(settings.themeMode);
    final isNarrow = MediaQuery.sizeOf(context).width < 650;
    if (isNarrow) return _narrowBar(context, scheme);

    return Container(
      height: barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: scheme.surface,
      child: CustomMultiChildLayout(
        delegate: _CentredBarLayout(gap: 16, maxCentre: 640),
        children: [
          // ── Left: Menu + Logo + App Name ──
          LayoutId(
            id: _BarSlot.left,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),

          // ── Centre: Search Bar ──
          LayoutId(
            id: _BarSlot.centre,
            child: _SearchPill(
              focusNode: focusNode,
              height: _pillHeight,
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Icon(Icons.search, color: scheme.onSurfaceVariant, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: onQuery,
                      textInputAction: TextInputAction.search,
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: 'Search your notes',
                        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
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

          // ── Right: Quick Settings & User Avatar Circle ──
          LayoutId(
            id: _BarSlot.right,
            child: Row(
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
                  // The sun/moon rotates in as the theme flips, a nod to the
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
                  tooltip: 'Theme: ${themeAction.label}, tap to change',
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
                  ? 'Semantic search on, results ranked by meaning'
                  : 'Search by meaning',
              onPressed: onToggleSemantic,
            ),
    );
  }

  /// Phone layout: the whole bar is a single search pill. The
  /// drawer button, search field, and the few icons that matter on a phone
  /// (chat, layout, avatar) live inside it; while typing they give way to
  /// clear + semantic-search. Sort/theme/settings tuck into the avatar menu,
  /// and branding lives in the drawer.
  Widget _narrowBar(BuildContext context, ColorScheme scheme) {
    final chatAvailable = context.watch<SettingsStore>().notesChatAvailable;

    return Container(
      height: barHeight,
      // Tighter than the desktop bar's inset on purpose: the pill here holds
      // real buttons, and this leaves them their full 48px touch target.
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
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

  Widget _selectionBar(BuildContext context, ColorScheme scheme) {
    final narrow = MediaQuery.sizeOf(context).width < 650;
    final selectionLabel = selectedCount == 0
        ? 'Select notes'
        : '$selectedCount selected';
    final controls = <Widget>[
      IconButton(
        icon: Icon(allSelected ? Icons.deselect_outlined : Icons.select_all),
        tooltip: allSelected ? 'Deselect all' : 'Select all',
        onPressed: onToggleSelectAll,
      ),
      if (narrow)
        PopupMenuButton<_SelectionAction>(
          popUpAnimationStyle: Motion.menuFor(context),
          enabled: selectedCount > 0,
          tooltip: 'More selected-note actions',
          onSelected: (action) async {
            if (action != _SelectionAction.pin) {
              await Motion.waitForMenuDismissal(context);
              if (!context.mounted) return;
            }
            switch (action) {
              case _SelectionAction.label:
                onAddLabelSelected();
              case _SelectionAction.stage:
                onMoveToStageSelected();
              case _SelectionAction.share:
                onShareSelected();
              case _SelectionAction.color:
                onSetColorSelected();
              case _SelectionAction.pin:
                onPinSelected();
            }
          },
          itemBuilder: (context) => [
            if (canMoveToStage)
              const PopupMenuItem(
                value: _SelectionAction.stage,
                child: ListTile(
                  leading: Icon(Icons.view_kanban_outlined),
                  title: Text('Move to column'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            const PopupMenuItem(
              value: _SelectionAction.label,
              child: ListTile(
                leading: Icon(Icons.label_outline),
                title: Text('Add label'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: _SelectionAction.share,
              child: ListTile(
                leading: Icon(Icons.person_add_alt_outlined),
                title: Text('Share'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: _SelectionAction.color,
              child: ListTile(
                leading: Icon(Icons.palette_outlined),
                title: Text('Change color'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: _SelectionAction.pin,
              child: ListTile(
                leading: Icon(
                  pinSelected ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(pinSelected ? 'Pin notes' : 'Unpin notes'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
          child: const SizedBox(
            width: 48,
            height: 48,
            child: Center(child: Icon(Icons.more_vert)),
          ),
        )
      else ...[
        if (canMoveToStage)
          IconButton(
            icon: const Icon(Icons.view_kanban_outlined),
            tooltip: 'Move selected notes to a column',
            onPressed: selectedCount == 0 ? null : onMoveToStageSelected,
          ),
        IconButton(
          icon: const Icon(Icons.label_outline),
          tooltip: 'Add label to selected notes',
          onPressed: selectedCount == 0 ? null : onAddLabelSelected,
        ),
        IconButton(
          icon: const Icon(Icons.person_add_alt_outlined),
          tooltip: 'Share selected notes',
          onPressed: selectedCount == 0 ? null : onShareSelected,
        ),
        IconButton(
          icon: const Icon(Icons.palette_outlined),
          tooltip: 'Change selected note colors',
          onPressed: selectedCount == 0 ? null : onSetColorSelected,
        ),
        IconButton(
          icon: Icon(pinSelected ? Icons.push_pin_outlined : Icons.push_pin),
          tooltip: pinSelected ? 'Pin selected notes' : 'Unpin selected notes',
          onPressed: selectedCount == 0 ? null : onPinSelected,
        ),
      ],
      if (canArchive)
        IconButton(
          icon: Icon(
            archiveSelected ? Icons.archive_outlined : Icons.unarchive_outlined,
          ),
          tooltip: archiveSelected
              ? 'Archive selected notes'
              : 'Unarchive selected notes',
          onPressed: selectedCount == 0 ? null : onArchiveSelected,
        ),
      if (canRestore)
        IconButton(
          icon: const Icon(Icons.restore_outlined),
          tooltip: 'Restore selected notes',
          onPressed: selectedCount == 0 ? null : onRestoreSelected,
        ),
      if (canTrash)
        IconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: 'Move selected notes to Trash',
          onPressed: selectedCount == 0 ? null : onTrashSelected,
        ),
    ];
    return _SelectionBar(
      label: selectionLabel,
      onCancel: onCancelSelection,
      actions: controls,
    );
  }
}

/// The bar in selection mode. Entering selection swaps the whole bar at once,
/// which read as a flicker: the actions now drop in from above, staggered left
/// to right, so the row announces itself as arriving. The entrance runs once
/// per stint in selection mode, picking further notes only re-enables the
/// icons already on screen, and replaying it on every tap would be noise.
class _SelectionBar extends StatefulWidget {
  final String label;
  final VoidCallback onCancel;
  final List<Widget> actions;

  const _SelectionBar({
    required this.label,
    required this.onCancel,
    required this.actions,
  });

  @override
  State<_SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends State<_SelectionBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: Motion.base,
  );

  @override
  void initState() {
    super.initState();
    _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (Motion.reduced(context)) _enter.value = 1;

    // The cancel button leads, then each action a beat later; the last one
    // still lands within Motion.base.
    final count = widget.actions.length + 1;
    Widget dropIn(int index, Widget child) {
      final step = count <= 1 ? 0.0 : 0.5 / (count - 1);
      final start = step * index;
      final animation = _enter.drive(
        CurveTween(
          curve: Interval(start, start + 0.5, curve: Motion.emphasized),
        ),
      );
      return SlideTransition(
        position: animation.drive(
          Tween(begin: const Offset(0, -0.75), end: Offset.zero),
        ),
        child: FadeTransition(opacity: animation, child: child),
      );
    }

    return Container(
      height: HomeTopBar.barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: scheme.surface,
      child: Row(
        children: [
          dropIn(
            0,
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel selection',
              onPressed: widget.onCancel,
            ),
          ),
          Expanded(
            // The count changes as you pick notes, so it fades rather than
            // dropping, it's the one thing here that isn't a new control.
            child: FadeTransition(
              opacity: _enter,
              child: Text(
                widget.label,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          for (final (i, action) in widget.actions.indexed)
            dropIn(i + 1, action),
        ],
      ),
    );
  }
}

enum _BarSlot { left, centre, right }

/// Lays the desktop bar out as branding | search | actions, with the search
/// pill centred on the *bar* rather than on the space left over between the
/// two clusters. A plain Row can only do the latter, and since the action
/// icons outweigh the branding the pill sat visibly right of centre.
///
/// The clusters keep their natural widths; the pill takes whatever is left
/// once both are cleared. When that drops below [_minCentre], a narrow
/// window, or a long enough action row, centring is abandoned rather than
/// squeezing the field to nothing, and the pill simply fills the gap.
class _CentredBarLayout extends MultiChildLayoutDelegate {
  /// Breathing room between the pill and each cluster.
  final double gap;

  /// The pill never grows past this, however wide the window gets.
  final double maxCentre;

  static const double _minCentre = 260;

  _CentredBarLayout({required this.gap, required this.maxCentre});

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final left = layoutChild(_BarSlot.left, loose);
    final right = layoutChild(_BarSlot.right, loose);

    final side = math.max(left.width, right.width);
    var width = math.min(maxCentre, size.width - 2 * (side + gap));
    double x;
    if (width >= _minCentre) {
      x = (size.width - width) / 2;
    } else {
      width = math.max(0, size.width - left.width - right.width - 2 * gap);
      x = left.width + gap;
    }
    final centre = layoutChild(
      _BarSlot.centre,
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: size.height),
    );

    double centred(Size child) =>
        ((size.height - child.height) / 2).clamp(0.0, size.height);
    positionChild(_BarSlot.left, Offset(0, centred(left)));
    positionChild(_BarSlot.centre, Offset(x, centred(centre)));
    positionChild(
      _BarSlot.right,
      Offset(size.width - right.width, centred(right)),
    );
  }

  @override
  bool shouldRelayout(_CentredBarLayout old) =>
      old.gap != gap || old.maxCentre != maxCentre;
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
/// gains focus it lifts, surface fill plus a soft shadow, so the active
/// search state is unmistakable.
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
    final themeAction = _currentThemeAction(settings.themeMode);

    return PopupMenuButton<String>(
      popUpAnimationStyle: Motion.menuFor(context),
      offset: const Offset(0, 48),
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
                Text('Theme: ${themeAction.label}'),
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
      onSelected: (value) async {
        if (value == 'settings' || value == 'sort' || value == 'logout') {
          await Motion.waitForMenuDismissal(context);
          if (!context.mounted) return;
        }
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
    if (widget.status == SyncStatus.syncing ||
        widget.status == SyncStatus.connecting) {
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
        'Offline, changes will sync when you reconnect',
      ),
      SyncStatus.connecting => (
        Icons.sync_rounded,
        scheme.primary,
        'Connecting to the server…',
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

/// Sort control: the available "Sort by" options. Anything but custom order
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
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<SortMode>(
      popUpAnimationStyle: Motion.menuFor(context),
      icon: const Icon(Icons.swap_vert),
      // Popup menus otherwise resolve their icon through a different theme
      // path than the neighboring IconButtons, which made this control read
      // as a different colour in the top bar.
      iconColor: scheme.onSurfaceVariant,
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
