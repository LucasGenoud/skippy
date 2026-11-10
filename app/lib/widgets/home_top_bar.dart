import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'animated_presence.dart';
import 'menu_label.dart';
import 'pin_icon.dart';
import 'package:provider/provider.dart';

import '../models/workspace.dart' show AiFeature;
import '../screens/chat_screen.dart';
import '../screens/settings_screen.dart';
import '../state/auth_store.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/motion.dart';
import 'screen_width.dart';
import 'app_icon_button.dart';

/// The top bar displays the active setting, matching Settings → Appearance.
/// Tapping still cycles to the next choice.
({IconData icon, String label}) _currentThemeAction(ThemeMode current) =>
    switch (current) {
      ThemeMode.system => (icon: Icons.brightness_auto_outlined, label: 'Auto'),
      ThemeMode.light => (icon: Icons.light_mode_outlined, label: 'Light'),
      ThemeMode.dark => (icon: Icons.dark_mode_outlined, label: 'Dark'),
    };

enum _SelectionAction { stage, label, share, color, pin }

/// What the selection bar shows and does: how many notes are picked, and what
/// the open view lets you do to them. The home screen owns the selection and
/// builds one of these while it lasts.
class SelectionActions {
  final int count;
  final bool allSelected;

  /// Whether the pin control pins (some are unpinned) or unpins (all are).
  final bool pinSelected;

  /// Whether the archive control archives or, inside the archive, unarchives.
  final bool archiveSelected;
  final bool canArchive;
  final bool canRestore;
  final bool canTrash;

  /// Bulk-file the selection into a board column. Only offered on the board,
  /// where columns are the thing on screen.
  final bool canMoveToStage;
  final VoidCallback onCancel;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onArchive;
  final VoidCallback onRestore;
  final VoidCallback onTrash;
  final VoidCallback onAddLabel;
  final VoidCallback onMoveToStage;
  final VoidCallback onSetColor;
  final VoidCallback onPin;
  final VoidCallback onShare;

  const SelectionActions({
    required this.count,
    required this.allSelected,
    required this.pinSelected,
    required this.archiveSelected,
    required this.canArchive,
    required this.canRestore,
    required this.canTrash,
    required this.canMoveToStage,
    required this.onCancel,
    required this.onToggleSelectAll,
    required this.onArchive,
    required this.onRestore,
    required this.onTrash,
    required this.onAddLabel,
    required this.onMoveToStage,
    required this.onSetColor,
    required this.onPin,
    required this.onShare,
  });
}

/// The home screen's top bar: menu + branding, the search pill (with clear
/// and semantic-search controls), and the quick-settings icons + avatar menu.
/// Below 650px it collapses into a single search pill.
class HomeTopBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool semantic;
  final bool semanticAvailable;
  final bool semanticBusy;
  final ValueChanged<String> onQuery;
  final VoidCallback onToggleSemantic;

  /// Opens the filter cheat sheet. It is the only place the `label:`/`is:`
  /// vocabulary is advertised, so the button sits in the pill itself.
  final VoidCallback onOpenFilters;

  /// Publishes the open view as a public link, or null when the current view
  /// is not something that can be published (trash, archive, reminders, a
  /// smart view, or a workspace this user does not own).
  final VoidCallback? onShareView;
  final VoidCallback onToggleSidebar;

  /// The selection bar's contents while notes are selected; null while
  /// browsing.
  final SelectionActions? selection;

  /// What is open: the collection, label, or library view. The wide bar leads
  /// with it, the way a document window names its document.
  final String title;

  const HomeTopBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.semantic,
    required this.semanticAvailable,
    required this.semanticBusy,
    required this.onQuery,
    required this.onToggleSemantic,
    required this.onOpenFilters,
    required this.onShareView,
    required this.onToggleSidebar,
    required this.selection,
    required this.title,
  });

  /// The bar's own height, and the search pill inside it.
  static const double barHeight = 60;
  static const double _pillHeight = 36;

  /// The wide bar's search field: enough for a query and its filter terms,
  /// not a centrepiece.
  static const double _searchWidth = 320;

  /// Notes chat needs the server's retrieval, and the open workspace to allow
  /// chat with a provider from its owner.
  static bool _chatAvailable(BuildContext context) =>
      context.select<SettingsStore, bool>((s) => s.semanticSearchCapable) &&
      context.select<NotesStore, bool>(
        (s) => s.aiIn(s.activeWorkspaceId).allows(AiFeature.chat),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // One switcher drives selection mode both ways: the selection bar's
    // actions drop in on entry and lift back out on exit, and the browsing
    // bar fades in behind them as they leave.
    return AnimatedSwitcher(
      duration: Motion.reduced(context) ? Duration.zero : Motion.base,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.passthrough, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        if (child.key == _selectingKey) {
          return _BarTransition(animation: animation, child: child);
        }
        return FadeTransition(
          opacity: animation.drive(
            CurveTween(curve: const Interval(0.4, 1, curve: Motion.standard)),
          ),
          child: child,
        );
      },
      child: switch (selection) {
        final selection? => KeyedSubtree(
          key: _selectingKey,
          child: _selectionBar(context, scheme, selection),
        ),
        null => KeyedSubtree(key: _browsingKey, child: _browsingBar(context)),
      },
    );
  }

  /// Whether the bar names the open view. A destination's own header leaves
  /// its title out where this holds, so the name is never shown twice.
  static bool showsTitle(BuildContext context) =>
      ScreenWidth.isAtLeast(context, _wideBarMinWidth);

  /// Below this the bar collapses into a single search pill.
  static const double _wideBarMinWidth = 650;

  static const _selectingKey = ValueKey('selecting');
  static const _browsingKey = ValueKey('browsing');

  Widget _browsingBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsStore>();
    final themeAction = _currentThemeAction(settings.themeMode);
    final isNarrow = !showsTitle(context);
    if (isNarrow) return _narrowBar(context, scheme);

    return Container(
      height: barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: scheme.surface,
      child: Row(
        children: [
          AppIconButton(
            icon: const Icon(Icons.menu),
            tooltip: 'Main menu',
            onPressed: onToggleSidebar,
          ),
          const SizedBox(width: kSpaceSm),
          // The view's name, cross-faded as you move between views.
          Expanded(
            child: AnimatedSwitcher(
              duration: Motion.reduced(context) ? Duration.zero : Motion.base,
              switchInCurve: Motion.standard,
              switchOutCurve: Motion.standard,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.centerLeft,
                children: [...previous, ?current],
              ),
              child: Text(
                title,
                key: ValueKey(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          const SizedBox(width: kSpaceLg),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _searchWidth),
              child: _SearchPill(
                focusNode: focusNode,
                height: _pillHeight,
                child: Row(
                  children: [
                    const SizedBox(width: kSpaceMd),
                    Icon(
                      Icons.search,
                      color: scheme.onSurfaceVariant,
                      size: 18,
                    ),
                    const SizedBox(width: kSpaceSm),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: onQuery,
                        textInputAction: TextInputAction.search,
                        style: Theme.of(context).textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: 'Search',
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
                            : AppIconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: 'Clear search',
                                onPressed: () {
                                  controller.clear();
                                  onQuery('');
                                },
                              ),
                      ),
                    ),
                    _filtersControl(),
                    if (semanticAvailable) _semanticControl(scheme),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: kSpaceSm),
          // Quick settings and the avatar menu.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // These two come and go with the view and the workspace's
              // AI, so they grow in and out rather than shoving the row.
              AnimatedPresence(
                axis: Axis.horizontal,
                layout: (children) =>
                    Row(mainAxisSize: MainAxisSize.min, children: children),
                children: [
                  if (_chatAvailable(context))
                    AppIconButton(
                      key: const ValueKey('chat'),
                      icon: const Icon(Icons.forum_outlined),
                      tooltip: 'Chat with your notes',
                      onPressed: () => ChatScreen.open(context),
                    ),
                  if (onShareView != null)
                    AppIconButton(
                      key: const ValueKey('share-view'),
                      icon: const Icon(Icons.ios_share),
                      tooltip: 'Share this view',
                      onPressed: onShareView,
                    ),
                ],
              ),
              const _SortButton(),
              AppIconButton(
                // The sun/moon rotates in as the theme flips, a nod to the
                // day/night metaphor without slowing the switch down.
                icon: AnimatedSwitcher(
                  duration: Motion.base,
                  switchInCurve: Motion.standard,
                  switchOutCurve: Motion.standard,
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
              AppIconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () =>
                    Navigator.of(context).push(SettingsScreen.route()),
              ),
              const SizedBox(width: 6),
              _UserAvatarMenu(onShareView: onShareView),
              const SizedBox(width: kSpaceXs),
            ],
          ),
        ],
      ),
    );
  }

  /// The in-pill filter control: opens the cheat sheet of search operators.
  Widget _filtersControl() => AppIconButton(
    icon: const Icon(Icons.tune, size: 20),
    tooltip: 'Search filters',
    onPressed: onOpenFilters,
  );

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
          : AppIconButton(
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
    final chatAvailable = _chatAvailable(context);

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
            AppIconButton(
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
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
                        AppIconButton(
                          icon: const Icon(Icons.close, size: 20),
                          tooltip: 'Clear search',
                          onPressed: () {
                            controller.clear();
                            onQuery('');
                          },
                        ),
                      _filtersControl(),
                      if (semanticAvailable) _semanticControl(scheme),
                      const SizedBox(width: kSpaceXs),
                    ],
                  );
                } else {
                  controls = Row(
                    key: const ValueKey('idle-mode'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (chatAvailable)
                        AppIconButton(
                          icon: const Icon(Icons.forum_outlined),
                          tooltip: 'Chat with your notes',
                          onPressed: () => ChatScreen.open(context),
                        ),
                      _UserAvatarMenu(onShareView: onShareView),
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

  Widget _selectionBar(
    BuildContext context,
    ColorScheme scheme,
    SelectionActions selection,
  ) {
    final narrow = !showsTitle(context);
    final selectionLabel = selection.count == 0
        ? 'Select notes'
        : '${selection.count} selected';
    final controls = <Widget>[
      AppIconButton(
        icon: _fadeScale(
          child: Icon(
            selection.allSelected ? Icons.deselect_outlined : Icons.select_all,
            key: ValueKey(selection.allSelected),
          ),
        ),
        tooltip: selection.allSelected ? 'Deselect all' : 'Select all',
        onPressed: selection.onToggleSelectAll,
      ),
      if (narrow)
        PopupMenuButton<_SelectionAction>(
          popUpAnimationStyle: Motion.menuFor(context),
          enabled: selection.count > 0,
          tooltip: 'More selected-note actions',
          onSelected: (action) async {
            if (action != _SelectionAction.pin) {
              await Motion.waitForMenuDismissal(context);
              if (!context.mounted) return;
            }
            switch (action) {
              case _SelectionAction.label:
                selection.onAddLabel();
              case _SelectionAction.stage:
                selection.onMoveToStage();
              case _SelectionAction.share:
                selection.onShare();
              case _SelectionAction.color:
                selection.onSetColor();
              case _SelectionAction.pin:
                selection.onPin();
            }
          },
          itemBuilder: (context) => [
            if (selection.canMoveToStage)
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
                  selection.pinSelected
                      ? Icons.push_pin_outlined
                      : Icons.push_pin,
                ),
                title: Text(
                  selection.pinSelected ? 'Pin notes' : 'Unpin notes',
                ),
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
        if (selection.canMoveToStage)
          AppIconButton(
            icon: const Icon(Icons.view_kanban_outlined),
            tooltip: 'Move selected notes to a column',
            onPressed: selection.count == 0 ? null : selection.onMoveToStage,
          ),
        AppIconButton(
          icon: const Icon(Icons.label_outline),
          tooltip: 'Add label to selected notes',
          onPressed: selection.count == 0 ? null : selection.onAddLabel,
        ),
        AppIconButton(
          icon: const Icon(Icons.person_add_alt_outlined),
          tooltip: 'Share selected notes',
          onPressed: selection.count == 0 ? null : selection.onShare,
        ),
        AppIconButton(
          icon: const Icon(Icons.palette_outlined),
          tooltip: 'Change selected note colors',
          onPressed: selection.count == 0 ? null : selection.onSetColor,
        ),
        AppIconButton(
          icon: PinIcon(pinned: !selection.pinSelected),
          tooltip: selection.pinSelected
              ? 'Pin selected notes'
              : 'Unpin selected notes',
          onPressed: selection.count == 0 ? null : selection.onPin,
        ),
      ],
      if (selection.canArchive)
        AppIconButton(
          icon: _fadeScale(
            child: Icon(
              selection.archiveSelected
                  ? Icons.archive_outlined
                  : Icons.unarchive_outlined,
              key: ValueKey(selection.archiveSelected),
            ),
          ),
          tooltip: selection.archiveSelected
              ? 'Archive selected notes'
              : 'Unarchive selected notes',
          onPressed: selection.count == 0 ? null : selection.onArchive,
        ),
      if (selection.canRestore)
        AppIconButton(
          icon: const Icon(Icons.restore_outlined),
          tooltip: 'Restore selected notes',
          onPressed: selection.count == 0 ? null : selection.onRestore,
        ),
      if (selection.canTrash)
        AppIconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: 'Move selected notes to Trash',
          onPressed: selection.count == 0 ? null : selection.onTrash,
        ),
    ];
    return _SelectionBar(
      label: selectionLabel,
      onCancel: selection.onCancel,
      actions: controls,
    );
  }
}

/// Hands the selection bar its switcher animation, so the same controller
/// plays its entrance forward and its exit in reverse.
class _BarTransition extends InheritedWidget {
  final Animation<double> animation;

  const _BarTransition({required this.animation, required super.child});

  static Animation<double> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BarTransition>()?.animation ??
      kAlwaysCompleteAnimation;

  @override
  bool updateShouldNotify(_BarTransition old) => old.animation != animation;
}

/// The bar in selection mode. Swapping the whole bar at once read as a
/// flicker, so the actions drop in from above, staggered left to right, and
/// leave the same way in reverse, right to left, when the selection ends. The
/// entrance runs once per stint in selection mode: picking further notes only
/// re-enables the icons already on screen.
class _SelectionBar extends StatelessWidget {
  final String label;
  final VoidCallback onCancel;
  final List<Widget> actions;

  const _SelectionBar({
    required this.label,
    required this.onCancel,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enter = _BarTransition.of(context);

    // The cancel button leads, then each action a beat later; the last one
    // still lands within Motion.base.
    final count = actions.length + 1;
    Widget dropIn(int index, Widget child) {
      final step = count <= 1 ? 0.0 : 0.5 / (count - 1);
      final start = step * index;
      final animation = enter.drive(
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
            AppIconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel selection',
              onPressed: onCancel,
            ),
          ),
          Expanded(
            // The count changes as you pick notes, so it fades rather than
            // dropping, it's the one thing here that isn't a new control.
            child: FadeTransition(
              opacity: enter.drive(CurveTween(curve: Motion.standard)),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          for (final (i, action) in actions.indexed) dropIn(i + 1, action),
        ],
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
            borderRadius: kBorderRadius,
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
  /// Below the wide breakpoint the bar has no room for a share button, so it
  /// joins sort and theme in here. Null when the open view cannot be shared.
  final VoidCallback? onShareView;

  const _UserAvatarMenu({this.onShareView});

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
    final issueCount = context.select<NotesStore, int>(
      (s) => s.syncIssues.length,
    );
    final cacheFailure = context.select<NotesStore, String?>(
      (s) => s.cacheFailure,
    );
    final issueLabel = issueCount == 1
        ? '1 change needs attention'
        : '$issueCount changes need attention';
    final themeAction = _currentThemeAction(settings.themeMode);

    return PopupMenuButton<String>(
      popUpAnimationStyle: Motion.menuFor(context),
      offset: const Offset(0, 48),
      tooltip:
          '${name.isEmpty ? 'Account' : name}, ${cacheFailure != null
              ? 'offline storage needs attention'
              : issueCount > 0
              ? issueLabel
              : syncStatus.name}',
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
              const SizedBox(width: kSpaceMd),
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
          value: 'sync',
          child: Row(
            children: [
              Icon(
                issueCount > 0 || cacheFailure != null
                    ? Icons.error_outline
                    : Icons.cloud_done_outlined,
                size: 20,
                color: issueCount > 0 || cacheFailure != null
                    ? scheme.error
                    : scheme.onSurface,
              ),
              const SizedBox(width: kSpaceMd),
              Flexible(
                child: Text(
                  cacheFailure != null
                      ? 'Offline storage needs attention'
                      : issueCount > 0
                      ? issueLabel
                      : 'Sync status: ${syncStatus.name}',
                  maxLines: 2,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 20, color: scheme.onSurface),
              const SizedBox(width: kSpaceMd),
              const Expanded(
                child: MenuLabel('Settings', hint: 'Account, theme, AI'),
              ),
            ],
          ),
        ),
        if (!HomeTopBar.showsTitle(context)) ...[
          if (onShareView != null)
            PopupMenuItem<String>(
              value: 'share-view',
              child: Row(
                children: [
                  Icon(Icons.ios_share, size: 20, color: scheme.onSurface),
                  const SizedBox(width: kSpaceMd),
                  const Expanded(
                    child: MenuLabel(
                      'Share this view',
                      hint: 'As a public link',
                    ),
                  ),
                ],
              ),
            ),
          PopupMenuItem<String>(
            value: 'sort',
            child: Row(
              children: [
                Icon(Icons.swap_vert, size: 20, color: scheme.onSurface),
                const SizedBox(width: kSpaceMd),
                const Expanded(
                  child: MenuLabel('Sort by', hint: 'Order of the notes'),
                ),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'theme',
            child: Row(
              children: [
                Icon(themeAction.icon, size: 20, color: scheme.onSurface),
                const SizedBox(width: kSpaceMd),
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
              const SizedBox(width: kSpaceMd),
              Text('Sign out', style: TextStyle(color: scheme.error)),
            ],
          ),
        ),
      ],
      onSelected: (value) async {
        if (value == 'sync' ||
            value == 'settings' ||
            value == 'sort' ||
            value == 'logout' ||
            value == 'share-view') {
          await Motion.waitForMenuDismissal(context);
          if (!context.mounted) return;
        }
        if (value == 'sync') {
          _showSyncSheet(context);
        } else if (value == 'share-view') {
          onShareView?.call();
        } else if (value == 'settings') {
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
        padding: const EdgeInsets.all(6.0),
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

void _showSyncSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Consumer<NotesStore>(
        builder: (context, store, _) => Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                'Sync status',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: kSpaceSm),
              if (store.cacheFailure != null) ...[
                const Text(
                  'This device could not save its offline copy. Keep the app open until changes reach the server.',
                ),
                TextButton(
                  onPressed: store.retryCacheWrite,
                  child: const Text('Retry offline save'),
                ),
              ],
              Text(
                store.syncIssues.isEmpty
                    ? store.cacheFailure != null
                          ? 'Offline copy was not saved'
                          : store.syncStatus == SyncStatus.offline
                          ? 'Offline. Changes will sync when you reconnect.'
                          : store.pendingChanges == 0
                          ? 'All changes saved'
                          : '${store.pendingChanges} pending changes'
                    : store.syncIssues.length == 1
                    ? '1 change needs attention'
                    : '${store.syncIssues.length} changes need attention',
              ),
              for (final issue in store.syncIssues) ...[
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    issue.label.isEmpty ? 'Untitled note' : issue.label,
                  ),
                  subtitle: Text(
                    issue.isConflict
                        ? 'This note changed elsewhere. Copy your edit before loading the server version.'
                        : issue.message,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (issue.copyText case final text? when text.isNotEmpty)
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Edit copied')),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Copy edit'),
                      ),
                    if (!issue.isConflict)
                      TextButton(
                        onPressed: () => store.retrySyncIssue(issue),
                        child: const Text('Retry'),
                      ),
                    if (issue.isConflict)
                      TextButton(
                        onPressed: () async {
                          await store.refresh();
                          if (context.mounted) Navigator.pop(context);
                        },
                        child: const Text('Load server version'),
                      ),
                    TextButton(
                      onPressed: () => store.dismissSyncIssue(issue),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// A small connectivity/sync indicator overlaid on the avatar: offline (no
/// server), syncing (unsynced local edits in flight, animated), or synced
/// (all changes saved). A bare glyph, no plate behind it.
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
      SyncStatus.failed => (
        Icons.error_rounded,
        scheme.error,
        'Changes need attention',
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
      child: RotationTransition(
        turns: _spin,
        child: Icon(
          icon,
          size: 13,
          color: color,
          // The glyph sits over the corner of the avatar and the bar at once.
          // A disc behind it would read as a sticker on the avatar, so it
          // carries its own soft shadow instead: enough to hold its edge
          // against the avatar's fill, invisible against the bar.
          shadows: [
            Shadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 2),
          ],
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
