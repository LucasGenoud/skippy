# Top Bar + Collapsible Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the slide-in-only `NavigationDrawer` and floating-search `SliverAppBar` with a fixed top bar (logo + search + account popover) and a persistent, collapsible left sidebar on wide screens, collapsing to a drawer on narrow screens (<600px).

**Architecture:** A new `AppShell` widget owns the responsive `Row(sidebar + body)` / `Scaffold(drawer + appBar)` layout. `HomeScreen` keeps all notes/grid logic and becomes the body of the shell. A shared `AppNavContent` widget (extracted from `AppDrawer`) is used by both the persistent sidebar and the narrow drawer so navigation logic is defined once. `AppDrawer` is deleted. Sidebar collapse state persists in `SettingsStore`.

**Tech Stack:** Flutter (Material 3), provider, existing `SettingsStore` JSON-sync pattern, existing `FakeApi`/widget-test harness.

**Reference spec:** `docs/superpowers/specs/2026-07-15-topbar-collapsible-sidebar-design.md`

---

## File Structure

| Action | Path | Responsibility |
|---|---|---|
| Create | `app/lib/widgets/app_nav_content.dart` | Single source of nav destinations, labels, label-edit, account footer. Parametrized by `collapsed`/`showLogout`/`onToggleCollapse`. Used by sidebar + drawer. |
| Create | `app/lib/widgets/app_top_bar.dart` | Fixed-height bar: hamburger (narrow) + logo + search field + sort/layout controls + account `MenuAnchor` popover (Settings/Theme/Sign out). |
| Create | `app/lib/widgets/app_sidebar.dart` | Persistent column (wide only): header (brand + collapse toggle) + `AppNavContent`. Animated width 240↔56. Reads/writes `SettingsStore.sidebarCollapsed`. |
| Create | `app/lib/widgets/app_shell.dart` | Responsive shell: `<600` → `Scaffold(drawer, appBar: AppTopBar, body)`; `>=600` → `Row(AppSidebar, Expanded(Column(AppTopBar, body)))`. |
| Create | `app/test/app_shell_test.dart` | Widget tests for `AppNavContent`, `AppSidebar`, `AppTopBar`, `AppShell` responsive behavior. |
| Delete | `app/lib/widgets/app_drawer.dart` | Replaced by `AppNavContent` + `AppSidebar` + drawer usage in `AppShell`. |
| Modify | `app/lib/state/settings_store.dart` | Add persisted `sidebarCollapsed` bool + setter. |
| Modify | `app/lib/screens/home_screen.dart` | Remove `Scaffold.drawer`/`SliverAppBar`/`_SearchBar`/`_SortButton`; delegate chrome to `AppShell`; keep grid/notes logic + keyboard shortcuts. |
| Modify | `app/test/settings_store_test.dart` | Add test for `sidebarCollapsed` roundtrip. |

---

### Task 1: Add `sidebarCollapsed` to `SettingsStore`

**Files:**
- Modify: `app/lib/state/settings_store.dart`
- Modify: `app/test/settings_store_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `app/test/settings_store_test.dart` (inside `main()`, after the existing tests, find the last `test(...)` block and add before the closing `}` of `main`):

```dart
  test('sidebarCollapsed defaults false and roundtrips', () async {
    await settings.load();
    expect(settings.sidebarCollapsed, isFalse);

    settings.setSidebarCollapsed(true);
    await settleSave();
    expect(api.settings['sidebar_collapsed'], isTrue);

    final other = SettingsStore(api: api);
    await other.load();
    expect(other.sidebarCollapsed, isTrue);

    other.setSidebarCollapsed(false);
    await settleSave();
    expect(api.settings['sidebar_collapsed'], isFalse);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/settings_store_test.dart --plain-name "sidebarCollapsed"`
Expected: FAIL, `sidebarCollapsed` getter and `setSidebarCollapsed` method don't exist (compile error / undefined name).

- [ ] **Step 3: Add the field, parsing, serialization, and setter**

In `app/lib/state/settings_store.dart`:

3a. Add the field. In the `SettingsStore` class, after `bool defaultListMode = false;` (line 137), add:

```dart
  bool sidebarCollapsed = false;
```

3b. Parse it. In `_applyJson`, after `defaultListMode = json['default_view'] == 'list';` (line 196), add:

```dart
    sidebarCollapsed = json['sidebar_collapsed'] == true;
```

3c. Serialize it. In `toJson`, after `'default_view': defaultListMode ? 'list' : 'grid',` (line 221), add:

```dart
    'sidebar_collapsed': sidebarCollapsed,
```

3d. Add the setter. After `void setDefaultListMode(bool value) => _mutate(() => defaultListMode = value);` (line 253), add:

```dart
  void setSidebarCollapsed(bool value) =>
      _mutate(() => sidebarCollapsed = value);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/settings_store_test.dart --plain-name "sidebarCollapsed"`
Expected: PASS

- [ ] **Step 5: Run the full settings test file to confirm no regressions**

Run: `cd app && flutter test test/settings_store_test.dart`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add app/lib/state/settings_store.dart app/test/settings_store_test.dart
git commit -m "feat: persist sidebarCollapsed in SettingsStore"
```

---

### Task 2: Create `AppNavContent` (extracted from `AppDrawer`)

**Files:**
- Create: `app/lib/widgets/app_nav_content.dart`
- Create: `app/test/app_shell_test.dart`

- [ ] **Step 1: Write the failing test**

Create `app/test/app_shell_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sticky_notes/models/note.dart';
import 'package:sticky_notes/state/auth_store.dart';
import 'package:sticky_notes/state/notes_store.dart';
import 'package:sticky_notes/state/settings_store.dart';
import 'package:sticky_notes/widgets/app_nav_content.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

Widget navHarness({
  required ViewSelection selection,
  bool collapsed = false,
  bool showLogout = false,
  List<Label> labels = const [],
  String? username = 'alice',
}) {
  final api = FakeApi();
  for (final l in labels) api.labels[l.id] = l;
  final store = NotesStore(api: api, currentUserId: 'u-me');
  final auth = AuthStore(api: api);
  // Inject a signed-in user without hitting the network.
  if (username != null) {
    auth.user = AuthUser(id: 'u-$username', username: username);
    auth.status = AuthStatus.signedIn;
  }
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider(create: (_) => SettingsStore(api: api)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          child: AppNavContent(
            selection: selection,
            collapsed: collapsed,
            showLogout: showLogout,
            onSelect: (_) {},
            onToggleCollapse: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('AppNavContent', () {
    testWidgets('expanded renders Notes/Reminders/Archive/Trash and account', (
      tester,
    ) async {
      await tester.pumpWidget(
        navHarness(selection: ViewSelection.notes, showLogout: true),
      );
      await tester.pump();

      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('Reminders'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Trash'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
    });

    testWidgets('renders label destinations and Edit labels row', (tester) async {
      await tester.pumpWidget(
        navHarness(
          selection: ViewSelection(NoteView.label, 'l1'),
          labels: const [Label(id: 'l1', name: 'Errands')],
        ),
      );
      await tester.pump();

      expect(find.text('Errands'), findsOneWidget);
      expect(find.text('Edit labels'), findsOneWidget);
    });

    testWidgets('empty labels shows Create labels', (tester) async {
      await tester.pumpWidget(navHarness(selection: ViewSelection.notes));
      await tester.pump();

      expect(find.text('Create labels'), findsOneWidget);
      expect(find.text('Edit labels'), findsNothing);
    });

    testWidgets('collapsed hides labels, edit row, and username', (tester) async {
      await tester.pumpWidget(
        navHarness(
          selection: ViewSelection.notes,
          collapsed: true,
          labels: const [Label(id: 'l1', name: 'Errands')],
        ),
      );
      await tester.pump();

      expect(find.text('Errands'), findsNothing);
      expect(find.text('Edit labels'), findsNothing);
      expect(find.text('Create labels'), findsNothing);
      expect(find.text('Labels'), findsNothing);
      expect(find.text('alice'), findsNothing);
      // The collapsed labels icon is present.
      expect(find.byIcon(Icons.sell_outlined), findsOneWidget);
    });

    testWidgets('tapping a destination calls onSelect', (tester) async {
      ViewSelection? picked;
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      final auth = AuthStore(api: api)
        ..user = AuthUser(id: 'u-alice', username: 'alice')
        ..status = AuthStatus.signedIn;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider(create: (_) => SettingsStore(api: api)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 240,
                child: AppNavContent(
                  selection: ViewSelection.notes,
                  onSelect: (s) => picked = s,
                  onToggleCollapse: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Reminders'));
      await tester.pump();
      expect(picked, ViewSelection.reminders);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppNavContent"`
Expected: FAIL, `AppNavContent` doesn't exist (compile error).

- [ ] **Step 3: Implement `AppNavContent`**

Create `app/lib/widgets/app_nav_content.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/auth_store.dart';
import '../state/notes_store.dart';
import 'labels_sheet.dart';

/// The shared navigation + account content used by both [AppSidebar] (wide,
/// persistent) and the narrow-screen drawer. Extracted from the old
/// `AppDrawer` so navigation logic is defined exactly once.
class AppNavContent extends StatelessWidget {
  final ViewSelection selection;
  final bool collapsed;
  final bool showLogout;
  final ValueChanged<ViewSelection> onSelect;
  final VoidCallback onToggleCollapse;

  const AppNavContent({
    super.key,
    required this.selection,
    this.collapsed = false,
    this.showLogout = false,
    required this.onSelect,
    required this.onToggleCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final auth = context.watch<AuthStore>();
    final labels = store.labels;
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _destination(
          context,
          ViewSelection.notes,
          Icons.lightbulb_outline,
          Icons.lightbulb,
          'Notes',
        ),
        _destination(
          context,
          ViewSelection.reminders,
          Icons.notifications_outlined,
          Icons.notifications,
          'Reminders',
        ),
        if (!collapsed) ...[
          _divider(),
          if (labels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
              child: Text(
                'Labels',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
        if (!collapsed)
          for (final label in labels)
            _destination(
              context,
              ViewSelection(NoteView.label, label.id),
              Icons.label_outline,
              Icons.label,
              label.name,
            )
        else if (labels.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.sell_outlined),
            title: const Text(''),
            tooltip: 'Labels',
            onTap: onToggleCollapse,
          ),
        if (!collapsed)
          InkWell(
            onTap: () => EditLabelsDialog.show(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_outlined,
                    size: 22,
                    color: scheme.onSurfaceVariant,
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
        _divider(),
        _destination(
          context,
          ViewSelection.archive,
          Icons.archive_outlined,
          Icons.archive,
          'Archive',
        ),
        _destination(
          context,
          ViewSelection.trash,
          Icons.delete_outline,
          Icons.delete,
          'Trash',
        ),
        _divider(),
        // Account footer.
        ListTile(
          contentPadding: EdgeInsets.symmetric(
            horizontal: collapsed ? 12 : 28,
          ),
          leading: CircleAvatar(
            radius: 14,
            child: Text(
              (auth.user?.username ?? '?').substring(0, 1).toUpperCase(),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          title: collapsed ? null : Text(auth.user?.username ?? ''),
          trailing: showLogout
              ? IconButton(
                  icon: const Icon(Icons.logout, size: 20),
                  tooltip: 'Sign out',
                  onPressed: () => auth.signOut(),
                )
              : null,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _destination(
    BuildContext context,
    ViewSelection value,
    IconData icon,
    IconData selectedIcon,
    String label,
  ) {
    final selected = value == selection;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onSelect(value),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 12 : 16,
          vertical: 14,
        ),
        child: Row(
          children: [
            Icon(
              selected ? selectedIcon : icon,
              size: 24,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            if (!collapsed) ...[
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : null,
                    color: selected ? scheme.primary : null,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _divider() => Padding(
    padding: EdgeInsets.fromLTRB(28, 8, 28, 8),
    child: Container(height: 1, color: Theme.of(context).dividerColor),
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppNavContent"`
Expected: PASS (all 5 tests)

- [ ] **Step 5: Run analyzer on the new file**

Run: `cd app && flutter analyze lib/widgets/app_nav_content.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add app/lib/widgets/app_nav_content.dart app/test/app_shell_test.dart
git commit -m "feat: extract AppNavContent from AppDrawer"
```

---

### Task 3: Create `AppTopBar`

**Files:**
- Create: `app/lib/widgets/app_top_bar.dart`
- Modify: `app/test/app_shell_test.dart` (add `AppTopBar` group)

- [ ] **Step 1: Write the failing test**

Add to `app/test/app_shell_test.dart` (append inside `main()`, after the `AppNavContent` group). Also add the needed imports at the top of the file:

```dart
import 'package:sticky_notes/widgets/app_top_bar.dart';
```

And add the `AppTopBar` test group:

```dart
  group('AppTopBar', () {
    late TextEditingController controller;
    late FocusNode focus;

    setUp(() {
      controller = TextEditingController();
      focus = FocusNode();
    });

    tearDown(() {
      controller.dispose();
      focus.dispose();
    });

    Widget topBarHarness({
      required VoidCallback onQuery,
      VoidCallback? onOpenDrawer,
      bool showHamburger = false,
      bool sidebarExpanded = false,
    }) {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      final auth = AuthStore(api: api)
        ..user = AuthUser(id: 'u-alice', username: 'alice')
        ..status = AuthStatus.signedIn;
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: api)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              child: AppTopBar(
                controller: controller,
                focusNode: focus,
                onQuery: onQuery,
                onOpenDrawer: onOpenDrawer ?? () {},
                showHamburger: showHamburger,
                sidebarExpanded: sidebarExpanded,
                listMode: false,
                onToggleLayout: () {},
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('typing in the search field calls onQuery', (tester) async {
      String? query;
      await tester.pumpWidget(
        topBarHarness(onQuery: () => query = controller.text),
      );
      await tester.enterText(find.byType(TextField), 'milk');
      expect(query, 'milk');
    });

    testWidgets('hamburger is shown only when showHamburger is true', (
      tester,
    ) async {
      await tester.pumpWidget(
        topBarHarness(onQuery: () {}, showHamburger: true),
      );
      expect(find.byIcon(Icons.menu), findsOneWidget);

      await tester.pumpWidget(
        topBarHarness(onQuery: () {}, showHamburger: false),
      );
      expect(find.byIcon(Icons.menu), findsNothing);
    });

    testWidgets('brand is hidden when sidebar is expanded', (tester) async {
      await tester.pumpWidget(
        topBarHarness(onQuery: () {}, sidebarExpanded: true),
      );
      expect(find.text('Sticky Notes'), findsNothing);

      await tester.pumpWidget(
        topBarHarness(onQuery: () {}, sidebarExpanded: false),
      );
      expect(find.text('Sticky Notes'), findsOneWidget);
    });

    testWidgets('account avatar menu shows Settings, Theme, Sign out', (
      tester,
    ) async {
      await tester.pumpWidget(topBarHarness(onQuery: () {}));
      await tester.tap(find.byType(CircleAvatar));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppTopBar"`
Expected: FAIL, `AppTopBar` doesn't exist (compile error).

- [ ] **Step 3: Implement `AppTopBar`**

Create `app/lib/widgets/app_top_bar.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../screens/settings_screen.dart';
import '../state/auth_store.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';

/// Fixed-height top bar: hamburger (narrow) + logo + search + sort/layout +
/// account popover (Settings / Theme / Sign out).
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onQuery;
  final VoidCallback onOpenDrawer;
  final bool showHamburger;
  final bool sidebarExpanded;
  final bool listMode;
  final VoidCallback onToggleLayout;
  final bool semantic;
  final bool semanticAvailable;
  final bool semanticBusy;
  final VoidCallback? onToggleSemantic;

  const AppTopBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onQuery,
    required this.onOpenDrawer,
    required this.showHamburger,
    required this.sidebarExpanded,
    required this.listMode,
    required this.onToggleLayout,
    this.semantic = false,
    this.semanticAvailable = false,
    this.semanticBusy = false,
    this.onToggleSemantic,
  });

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = scheme.brightness == Brightness.light;
    final showBrand = !sidebarExpanded;

    return Material(
      color: light ? scheme.surface : scheme.surfaceContainer,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            if (showHamburger)
              IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Menu',
                onPressed: onOpenDrawer,
              ),
            if (showBrand) ...[
              Icon(
                Icons.sticky_note_2_rounded,
                color: scheme.primary,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                'Sticky Notes',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 16),
            ],
            // Search field.
            Expanded(
              child: Material(
                color: light ? scheme.surface : scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          onChanged: onQuery,
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            hintText: 'Search your notes',
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
                      if (semanticAvailable)
                        semanticBusy
                            ? const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 10),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: Icon(
                                  Icons.auto_awesome,
                                  size: 20,
                                  color: semantic
                                      ? scheme.primary
                                      : null,
                                ),
                                tooltip: semantic
                                    ? 'Semantic search on, results ranked by meaning'
                                    : 'Search by meaning',
                                onPressed: onToggleSemantic,
                              ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Sort + layout toggles.
            _SortButton(),
            IconButton(
              icon: Icon(
                listMode
                    ? Icons.grid_view_outlined
                    : Icons.view_agenda_outlined,
              ),
              tooltip: listMode ? 'Grid view' : 'List view',
              onPressed: onToggleLayout,
            ),
            const SizedBox(width: 4),
            // Account popover.
            _AccountMenu(),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    return PopupMenuButton<SortMode>(
      icon: const Icon(Icons.swap_vert),
      tooltip: 'Sort by',
      initialValue: store.sortMode,
      onSelected: store.setSortMode,
      itemBuilder: (context) => [
        for (final (mode, label) in [
          (SortMode.custom, 'Custom order'),
          (SortMode.edited, 'Recently edited'),
          (SortMode.newest, 'Recently added'),
          (SortMode.oldest, 'Oldest first'),
        ])
          CheckedPopupMenuItem(
            value: mode,
            checked: store.sortMode == mode,
            child: Text(label),
          ),
      ],
    );
  }
}

class _AccountMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final settings = context.watch<SettingsStore>();
    final username = auth.user?.username ?? '?';
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_outlined),
          child: const Text('Settings'),
          onPressed: () =>
              Navigator.of(context).push(SettingsScreen.route()),
        ),
        MenuItemButton(
          leadingIcon: Icon(
            Theme.of(context).brightness == Brightness.light
                ? Icons.dark_mode_outlined
                : Icons.light_mode_outlined,
          ),
          child: const Text('Theme'),
          onPressed: () => settings.toggleTheme(Theme.of(context).brightness),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout),
          child: const Text('Sign out'),
          onPressed: () => auth.signOut(),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          icon: CircleAvatar(
            radius: 16,
            child: Text(
              username.substring(0, 1).toUpperCase(),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          tooltip: username,
          onPressed: () => controller.isOpen
              ? controller.close()
              : controller.open(),
        );
      },
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppTopBar"`
Expected: PASS (all 4 tests)

- [ ] **Step 5: Run analyzer**

Run: `cd app && flutter analyze lib/widgets/app_top_bar.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add app/lib/widgets/app_top_bar.dart app/test/app_shell_test.dart
git commit -m "feat: add AppTopBar with search and account popover"
```

---

### Task 4: Create `AppSidebar`

**Files:**
- Create: `app/lib/widgets/app_sidebar.dart`
- Modify: `app/test/app_shell_test.dart` (add `AppSidebar` group)

- [ ] **Step 1: Write the failing test**

Add to `app/test/app_shell_test.dart`. Add the import at top:

```dart
import 'package:sticky_notes/widgets/app_sidebar.dart';
```

Add the test group inside `main()`:

```dart
  group('AppSidebar', () {
    Widget sidebarHarness({required bool startCollapsed}) {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      api.labels['l1'] = const Label(id: 'l1', name: 'Errands');
      final auth = AuthStore(api: api)
        ..user = AuthUser(id: 'u-alice', username: 'alice')
        ..status = AuthStatus.signedIn;
      final settings = SettingsStore(api: api)
        ..sidebarCollapsed = startCollapsed;
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AppSidebar(
              selection: ViewSelection.notes,
              onSelect: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('expanded shows brand, labels, and username', (tester) async {
      await tester.pumpWidget(sidebarHarness(startCollapsed: false));
      await tester.pumpAndSettle();

      expect(find.text('Sticky Notes'), findsOneWidget);
      expect(find.text('Errands'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.byIcon(Icons.menu_open), findsOneWidget);
    });

    testWidgets('collapsed shows icon-only: no labels, no username', (
      tester,
    ) async {
      await tester.pumpWidget(sidebarHarness(startCollapsed: true));
      await tester.pumpAndSettle();

      expect(find.text('Errands'), findsNothing);
      expect(find.text('alice'), findsNothing);
      expect(find.text('Sticky Notes'), findsNothing);
      expect(find.byIcon(Icons.menu), findsOneWidget); // collapse toggle icon
    });

    testWidgets('toggling collapse flips SettingsStore.sidebarCollapsed', (
      tester,
    ) async {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      final auth = AuthStore(api: api)
        ..user = AuthUser(id: 'u-alice', username: 'alice')
        ..status = AuthStatus.signedIn;
      final settings = SettingsStore(api: api);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AppSidebar(
                selection: ViewSelection.notes,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(settings.sidebarCollapsed, isFalse);
      await tester.tap(find.byIcon(Icons.menu_open));
      await tester.pumpAndSettle();
      expect(settings.sidebarCollapsed, isTrue);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppSidebar"`
Expected: FAIL, `AppSidebar` doesn't exist (compile error).

- [ ] **Step 3: Implement `AppSidebar`**

Create `app/lib/widgets/app_sidebar.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/settings_store.dart';
import 'app_nav_content.dart';

/// Persistent left sidebar for wide screens. Collapses to an icon-only rail.
class AppSidebar extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;

  const AppSidebar({
    super.key,
    required this.selection,
    required this.onSelect,
  });

  static const _expandedWidth = 240.0;
  static const _collapsedWidth = 56.0;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final collapsed = settings.sidebarCollapsed;
    final scheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: collapsed ? _collapsedWidth : _expandedWidth,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(
          right: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        children: [
          // Header: brand + collapse toggle.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Icon(
                  Icons.sticky_note_2_rounded,
                  color: scheme.primary,
                  size: 24,
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sticky Notes',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                IconButton(
                  icon: Icon(collapsed ? Icons.menu : Icons.menu_open),
                  tooltip: collapsed ? 'Expand' : 'Collapse',
                  onPressed: () => settings.setSidebarCollapsed(!collapsed),
                ),
              ],
            ),
          ),
          Expanded(
            child: AppNavContent(
              selection: selection,
              collapsed: collapsed,
              showLogout: false,
              onSelect: onSelect,
              onToggleCollapse: () =>
                  settings.setSidebarCollapsed(!collapsed),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppSidebar"`
Expected: PASS (all 3 tests)

- [ ] **Step 5: Run analyzer**

Run: `cd app && flutter analyze lib/widgets/app_sidebar.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add app/lib/widgets/app_sidebar.dart app/test/app_shell_test.dart
git commit -m "feat: add collapsible AppSidebar"
```

---

### Task 5: Create `AppShell` (responsive)

**Files:**
- Create: `app/lib/widgets/app_shell.dart`
- Modify: `app/test/app_shell_test.dart` (add `AppShell` group)

- [ ] **Step 1: Write the failing test**

Add to `app/test/app_shell_test.dart`. Add imports at top:

```dart
import 'package:sticky_notes/widgets/app_shell.dart';
```

Add the test group:

```dart
  group('AppShell', () {
    Widget shellHarness({required double width}) {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      final auth = AuthStore(api: api)
        ..user = AuthUser(id: 'u-alice', username: 'alice')
        ..status = AuthStatus.signedIn;
      final settings = SettingsStore(api: api);
      final controller = TextEditingController();
      final focus = FocusNode();
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          home: SizedBox(
            width: width,
            height: 800,
            child: AppShell(
              selection: ViewSelection.notes,
              onSelect: (_) {},
              query: '',
              onQuery: (_) {},
              searchController: controller,
              searchFocus: focus,
              listMode: false,
              onToggleLayout: () {},
              body: const Center(child: Text('body')),
            ),
          ),
        ),
      );
    }

    testWidgets('narrow width renders drawer + topbar, no sidebar', (
      tester,
    ) async {
      await tester.pumpWidget(shellHarness(width: 400));
      await tester.pump();

      // Hamburger visible (opens drawer).
      expect(find.byIcon(Icons.menu), findsOneWidget);
      // No persistent sidebar.
      expect(find.byType(AppSidebar), findsNothing);
      // Drawer content is not visible until opened, but the Scaffold has one.
      expect(find.byType(Drawer), findsNothing); // closed
    });

    testWidgets('wide width renders sidebar + topbar, no hamburger', (
      tester,
    ) async {
      await tester.pumpWidget(shellHarness(width: 1000));
      await tester.pump();

      expect(find.byType(AppSidebar), findsOneWidget);
      // No hamburger on wide screens.
      expect(find.byIcon(Icons.menu), findsNothing);
    });

    testWidgets('body content is rendered in both layouts', (tester) async {
      await tester.pumpWidget(shellHarness(width: 1000));
      await tester.pump();
      expect(find.text('body'), findsOneWidget);

      await tester.pumpWidget(shellHarness(width: 400));
      await tester.pump();
      expect(find.text('body'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppShell"`
Expected: FAIL, `AppShell` doesn't exist (compile error).

- [ ] **Step 3: Implement `AppShell`**

Create `app/lib/widgets/app_shell.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/settings_store.dart';
import 'app_nav_content.dart';
import 'app_sidebar.dart';
import 'app_top_bar.dart';

/// Responsive shell: persistent sidebar + fixed topbar on wide screens;
/// drawer + topbar on narrow screens.
class AppShell extends StatelessWidget {
  final ViewSelection selection;
  final ValueChanged<ViewSelection> onSelect;
  final String query;
  final ValueChanged<String> onQuery;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final bool listMode;
  final VoidCallback onToggleLayout;
  final bool semantic;
  final bool semanticAvailable;
  final bool semanticBusy;
  final VoidCallback? onToggleSemantic;
  final Widget body;

  const AppShell({
    super.key,
    required this.selection,
    required this.onSelect,
    required this.query,
    required this.onQuery,
    required this.searchController,
    required this.searchFocus,
    required this.listMode,
    required this.onToggleLayout,
    this.semantic = false,
    this.semanticAvailable = false,
    this.semanticBusy = false,
    this.onToggleSemantic,
    required this.body,
  });

  static const _breakpoint = 600.0;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _breakpoint;
    final sidebarCollapsed = context.read<SettingsStore>().sidebarCollapsed;
    final sidebarExpanded = wide && !sidebarCollapsed;

    final topBar = AppTopBar(
      controller: searchController,
      focusNode: searchFocus,
      onQuery: onQuery,
      onOpenDrawer: () => Scaffold.of(context).openDrawer(),
      showHamburger: !wide,
      sidebarExpanded: sidebarExpanded,
      listMode: listMode,
      onToggleLayout: onToggleLayout,
      semantic: semantic,
      semanticAvailable: semanticAvailable,
      semanticBusy: semanticBusy,
      onToggleSemantic: onToggleSemantic,
    );

    if (wide) {
      return Row(
        children: [
          AppSidebar(selection: selection, onSelect: onSelect),
          Expanded(
            child: Column(
              children: [
                topBar,
                Expanded(child: body),
              ],
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: topBar,
      drawer: Drawer(
        child: SafeArea(
          child: AppNavContent(
            selection: selection,
            collapsed: false,
            showLogout: true,
            onSelect: (s) {
              Navigator.of(context).pop();
              onSelect(s);
            },
            onToggleCollapse: () {},
          ),
        ),
      ),
      body: body,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/app_shell_test.dart --plain-name "AppShell"`
Expected: PASS (all 3 tests)

- [ ] **Step 5: Run analyzer**

Run: `cd app && flutter analyze lib/widgets/app_shell.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add app/lib/widgets/app_shell.dart app/test/app_shell_test.dart
git commit -m "feat: add responsive AppShell"
```

---

### Task 6: Wire `AppShell` into `HomeScreen` and delete `AppDrawer`

**Files:**
- Modify: `app/lib/screens/home_screen.dart`
- Delete: `app/lib/widgets/app_drawer.dart`
- Modify: `app/test/widget_test.dart` (fix the FAB-slot test which asserts on `Scaffold.drawer`)

- [ ] **Step 1: Update the FAB-slot test to match the new shell**

The existing test `'note FABs stay out of the Scaffold slot'` (`widget_test.dart:689`) finds `Scaffold` and asserts `floatingActionButton` is null. After wiring, the `HomeScreen` still uses a `Scaffold` in the narrow layout, and the FABs are still in the body. The assertion `scaffold.floatingActionButton` is null should still hold. But the test also does `find.byType(Scaffold).first`, with `AppShell`, on wide screens there's no `Scaffold` wrapping the body (it's a `Row`), so the test's default 800px-wide test surface is >=600, meaning wide layout, meaning no `Scaffold`. The test will fail because `find.byType(Scaffold)` finds nothing.

Update `app/test/widget_test.dart`, in the `'note FABs stay out of the Scaffold slot'` test, replace the assertion block. Find:

```dart
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
        expect(scaffold.floatingActionButton, isNull);
        expect(find.byIcon(Icons.add), findsWidgets); // FABs still rendered
```

Replace with:

```dart
        // The note-creation FABs live inside the body (not a Scaffold slot)
        // so a floating SnackBar hugs the bottom.
        expect(find.byIcon(Icons.add), findsWidgets); // FABs still rendered
        final scaffoldMatch = find.byType(Scaffold);
        if (scaffoldMatch.evaluate().isNotEmpty) {
          final scaffold = tester.widget<Scaffold>(scaffoldMatch.first);
          expect(scaffold.floatingActionButton, isNull);
        }
```

- [ ] **Step 2: Run the FAB test to confirm it still passes with the old HomeScreen (pre-refactor)**

Run: `cd app && flutter test test/widget_test.dart --plain-name "note FABs stay out of the Scaffold slot"`
Expected: PASS (the old `HomeScreen` still has a `Scaffold` at this point, we haven't refactored it yet, so this is a baseline).

- [ ] **Step 3: Refactor `HomeScreen.build` to use `AppShell`**

In `app/lib/screens/home_screen.dart`:

3a. Remove the `app_drawer.dart` import (line 15) and add the new imports. Replace:

```dart
import '../widgets/app_drawer.dart';
```

with:

```dart
import '../widgets/app_shell.dart';
```

3b. Replace the `Scaffold(...)` body block. Find the block starting at `return CallbackShortcuts(` (line 197) and ending at its closing (line 370). Replace the entire `return CallbackShortcuts( ... );` expression with:

```dart
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN): _newNote,
        const SingleActivator(LogicalKeyboardKey.slash): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
      },
      child: FileDropArea(
        hint: 'Drop files to create a note',
        onFiles: _createNoteFromDrop,
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: AppShell(
            selection: _selection,
            onSelect: _selectView,
            query: _query,
            onQuery: _onQueryChanged,
            searchController: _searchController,
            searchFocus: _searchFocus,
            listMode: _listMode,
            onToggleLayout: () => setState(() => _listMode = !_listMode),
            semantic: _semantic,
            semanticAvailable: semanticAvailable,
            semanticBusy: _semanticBusy,
            onToggleSemantic: _toggleSemantic,
            body: Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final horizontalPad = width >= 900 ? 32.0 : 16.0;
                      final contentWidth = width - horizontalPad * 2;
                      final gridMaxWidth = _listMode ? 600.0 : 1400.0;
                      final effectiveWidth = contentWidth > gridMaxWidth
                          ? gridMaxWidth
                          : contentWidth;
                      final columns = _listMode
                          ? 1
                          : (effectiveWidth / 250).floor().clamp(2, 5);

                      return RefreshIndicator(
                        onRefresh: store.load,
                        edgeOffset: 80,
                        child: CustomScrollView(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            if (store.offline)
                              SliverToBoxAdapter(
                                child: _OfflineBanner(onRetry: store.retryNow),
                              ),
                            // Keep-style quick add: wide screens, main notes view only.
                            if (_selection == ViewSelection.notes &&
                                !searching &&
                                width >= 600)
                              SliverToBoxAdapter(
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 600,
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        12,
                                        16,
                                        24,
                                      ),
                                      child: QuickAddBar(),
                                    ),
                                  ),
                                ),
                              ),
                            if (_viewTitle(store).isNotEmpty)
                              SliverToBoxAdapter(
                                child: _ViewHeader(
                                  title: _viewTitle(store),
                                  isTrash: _selection.view == NoteView.trash,
                                  hasTrashedNotes: sections.others.isNotEmpty,
                                  onEmptyTrash: () => _confirmEmptyTrash(store),
                                ),
                              ),
                            if (store.loading)
                              SliverToBoxAdapter(
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: gridMaxWidth,
                                    ),
                                    child: Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        horizontalPad,
                                        8,
                                        horizontalPad,
                                        0,
                                      ),
                                      child: NotesSkeleton(columns: columns),
                                    ),
                                  ),
                                ),
                              )
                            else if (sections.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: EmptyState(
                                  icon: searching
                                      ? Icons.search_off
                                      : _emptyIcon,
                                  message: searching
                                      ? 'No matching notes'
                                      : _emptyMessage,
                                ),
                              )
                            else ...[
                              if (sections.pinned.isNotEmpty) ...[
                                _sectionLabel(context, 'Pinned', horizontalPad),
                                _grid(
                                  store,
                                  sections.pinned,
                                  columns,
                                  horizontalPad,
                                  gridMaxWidth,
                                  dragEnabled,
                                  section: 'pinned',
                                ),
                                if (sections.others.isNotEmpty)
                                  _sectionLabel(
                                    context,
                                    'Others',
                                    horizontalPad,
                                  ),
                              ],
                              _grid(
                                store,
                                sections.others,
                                columns,
                                horizontalPad,
                                gridMaxWidth,
                                dragEnabled,
                                section: 'others',
                              ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 200),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const Positioned(right: 16, bottom: 16, child: _NewNoteFabs()),
              ],
            ),
          ),
        ),
      ),
    );
```

3c. Delete the `_SearchBar` class (lines 442–566) and the `_SortButton` class (lines 660–686), they've moved to `AppTopBar`. Keep `_ViewHeader`, `_OfflineBanner`, `_NewNoteFabs`, `_AudioNoteFab`.

- [ ] **Step 4: Delete `app_drawer.dart`**

Run: `rm app/lib/widgets/app_drawer.dart`

- [ ] **Step 5: Run the analyzer on the modified files**

Run: `cd app && flutter analyze lib/screens/home_screen.dart lib/widgets/app_shell.dart`
Expected: No issues found.

- [ ] **Step 6: Run the full widget test suite**

Run: `cd app && flutter test test/widget_test.dart`
Expected: all PASS

- [ ] **Step 7: Run the full test suite**

Run: `cd app && flutter test`
Expected: all PASS

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: wire AppShell into HomeScreen, remove AppDrawer"
```

---

### Task 7: Verify the full build

**Files:** none

- [ ] **Step 1: Run the full analyzer**

Run: `cd app && flutter analyze`
Expected: No issues found.

- [ ] **Step 2: Run the full test suite**

Run: `cd app && flutter test`
Expected: all PASS

- [ ] **Step 3: Build the web target to confirm it compiles**

Run: `cd app && flutter build web --no-pub 2>&1 | tail -5`
Expected: succeeds (no compile errors)

- [ ] **Step 4: Commit if any formatting/fixes were needed**

If the previous steps required any adjustments, commit them:

```bash
git add -A
git commit -m "chore: build verification"
```
