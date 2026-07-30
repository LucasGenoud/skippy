# Top Bar + Collapsible Sidebar, Design

**Date:** 2026-07-15
**Status:** Approved (pending implementation)

## Goal

Replace the current slide-in-only `NavigationDrawer` and floating-search-bar "top chrome" with a proper fixed top bar and a persistent, collapsible left sidebar on wide screens, while staying compact on mobile (where the sidebar collapses to a drawer).

## Current state

- The entire signed-in shell lives in `HomeScreen.build` as a single `Scaffold`.
- There is **no top app bar**. The "top chrome" is a `SliverAppBar` whose `title` *is* the search bar (`_SearchBar`, `home_screen.dart:442`), which also crams in the hamburger menu, sort, layout toggle, and theme toggle.
- All navigation, brand, Notes/Reminders/Archive/Trash, labels, label-edit, Settings, account, lives in a Material `NavigationDrawer` (`widgets/app_drawer.dart`), opened via the hamburger inside the search bar.
- There is no `NavigationRail`, no responsive drawer↔rail swap, and no shared shell widget above `HomeScreen`.
- Logo is `Icons.sticky_note_2_rounded` (no raster/SVG asset). App title string is `'Sticky Notes'`.
- Width breakpoints today: `<480` hides theme toggle; `>=600` shows quick-add bar and dialog editor; `>=900` widens padding and allows 5 grid columns.

## Design

### Architecture

A new `AppShell` widget owns the responsive chrome. `HomeScreen` keeps all notes/grid logic and becomes the `body` of the shell. `AppDrawer` is retired and replaced by a shared `AppNavContent` widget used by both the persistent sidebar (wide) and the drawer (narrow), so navigation logic is defined once.

### Layout by width

| Width | Layout |
|---|---|
| `<600px` | `Scaffold` with `drawer:` (shared `AppNavContent`) opened from a hamburger button in the topbar. No persistent sidebar. |
| `>=600px` | `Row` → `AppSidebar` (expanded ~240px, collapsible to icon-rail ~56px) + `Column`(`AppTopBar` fixed + body slot). Hamburger hidden. |

Sidebar default state on wide screens is **expanded**. Collapse state persists across sessions via a new `SettingsStore.sidebarCollapsed` bool.

### Components

#### 1. `AppShell` (`widgets/app_shell.dart`)

Owns the responsive `Row`/`Scaffold` and wires callbacks between `AppTopBar`, `AppSidebar`, and the body.

Inputs:
- `body: Widget`, the notes content from `HomeScreen` (the `CustomScrollView` with offline banner, quick-add bar, view header, grid, FABs).
- `selection: ViewSelection`
- `onSelectView: void Function(ViewSelection)`
- `query: String`, `onQuery: void Function(String)`
- `searchController: TextEditingController`, `searchFocus: FocusNode` (kept owned by `HomeScreen` so keyboard shortcuts `/`/Cmd+K still work)
- `listMode: bool`, `onToggleListMode`, `sortMode: SortMode`, `onSortMode`
- semantic-search wiring callbacks (unchanged from current)

Behavior:
- Uses `LayoutBuilder` / `MediaQuery.sizeOf(context).width` to pick the layout.
- On narrow: renders `Scaffold(drawer: Drawer(child: AppNavContent(...)), appBar: AppTopBar(...), body: body)`. `AppTopBar` shows the hamburger which calls `Scaffold.of(context).openDrawer()`.
- On wide: renders `Row(children: [AppSidebar(...), Expanded(child: Column(children: [AppTopBar(...), Expanded(child: body)]))])`. No `Scaffold.drawer`; topbar hamburger hidden.
- Preserves the existing `CallbackShortcuts` + `FileDropArea` wrappers from `HomeScreen.build` (these stay in `HomeScreen` and wrap `AppShell`, OR move into `AppShell`, prefer keeping in `HomeScreen` to minimize change).

#### 2. `AppTopBar` (`widgets/app_top_bar.dart`)

A fixed-height (56) bar. A plain `AppBar`-like `Container`/`Material` (not a `SliverAppBar`) so it does not float or hide on scroll.

Layout (left → right):
- **Left:** hamburger `IconButton` (`Icons.menu`), **narrow only**, opens the drawer via a callback `onOpenDrawer`. Then the logo `Icons.sticky_note_2_rounded` (primary color, size 24) + `'Sticky Notes'` text. The brand is hidden when the sidebar is expanded on wide screens (the sidebar already shows it); shown when the sidebar is collapsed or on narrow.
- **Center:** the search `TextField`, rounded chip style (reuse current `_SearchBar` visuals minus the menu/sort/layout/theme controls). Wired to `searchController`/`searchFocus`/`onQuery`. Keeps the clear button and semantic-search toggle/spinner. Expands to fill available width.
- **Right:** a small `_SortButton` (popup menu, unchanged) and layout-toggle icon button (both inline on wide; on narrow, collapse into the same popup menu as sort to save space). Then the account avatar (`CircleAvatar` with first letter of username) → `MenuAnchor` popover with three items: **Settings** (pushes `SettingsScreen.route()`), **Theme** (toggle via `SettingsStore.toggleTheme`), **Sign out** (`AuthStore.signOut()`).

Reads `AuthStore` and `SettingsStore` via provider for the avatar/theme.

#### 3. `AppSidebar` (`widgets/app_sidebar.dart`)

A persistent `Column` for wide screens only.

Structure:
- **Header:** brand row (`Icons.sticky_note_2_rounded` + `'Sticky Notes'`) when expanded; just the icon when collapsed. A collapse-toggle `IconButton` (`Icons.menu_open` when expanded → `Icons.menu` when collapsed) at the top-right of the header.
- **Body:** `Expanded(child: AppNavContent(collapsed: ..., showLogout: false, ...))`.

Widths: expanded = 240, collapsed = 56. Animated width transition (200ms) via `AnimatedContainer`. `AppSidebar` does **not** add its own account footer, the account row lives inside `AppNavContent` (shared with the narrow drawer). Logout lives in the topbar account popover on wide; in the drawer footer on narrow (via `showLogout`).

Reads `SettingsStore.sidebarCollapsed` and calls `SettingsStore.setSidebarCollapsed(bool)` on toggle.

#### 4. `AppNavContent` (`widgets/app_nav_content.dart`)

Extracted from `AppDrawer`'s destination data (`app_drawer.dart:21-63`), the single source of nav destinations. A `ListView`-style column rendering:

- Notes, Reminders destinations
- Divider
- Labels section: header "Labels" (expanded only) + one destination per label (`ViewSelection(NoteView.label, label.id)`). When `collapsed`, the labels list collapses to a **single** `Icons.sell_outlined` icon with a tooltip `'Labels'`; tapping it expands the sidebar (calls `onToggleCollapse`). This avoids a tiny per-label icon list in the narrow rail.
- Label-edit / create-labels row → `EditLabelsDialog.show` (expanded only; hidden when collapsed)
- Divider
- Archive, Trash destinations
- Divider
- **Account footer:** `CircleAvatar` (first letter of username) + username (expanded only). On narrow (`showLogout: true`) it also shows a logout `IconButton` → `AuthStore.signOut()`. On wide (`showLogout: false`) the footer is avatar (+username when expanded) only; logout is in the topbar popover.

Params:
- `collapsed: bool`, when true, renders icon-only destinations.
- `showLogout: bool`, true in the narrow drawer, false in the wide sidebar.
- `onToggleCollapse: void Function()`, called when the collapsed labels icon is tapped (only meaningful in the sidebar; the drawer passes `collapsed: false` and a no-op).
- `selection: ViewSelection`, `onSelect: void Function(ViewSelection)`
- `labels: List<Label>`

Used by both `AppSidebar` (wide, `collapsed` from settings) and the narrow drawer (always `collapsed: false`).

### `HomeScreen` changes

- Remove `Scaffold.drawer:` and the `AppDrawer` import.
- Remove the `SliverAppBar` (lines 241-259) and its `_SearchBar` title; delete the `_SearchBar` class (lines 442-566), `_SortButton` (lines 660-686), and the inline theme-toggle code. These move into `AppTopBar`.
- The `CustomScrollView` now starts directly with the offline banner sliver (260), quick-add bar sliver (268), `_ViewHeader` sliver (287), and grid sections. It becomes the `body` passed to `AppShell`.
- Keep `_query`, `_listMode`, `_selection`, `_searchController`, `_searchFocus`, sort mode, semantic-search state, keyboard shortcuts, `FileDropArea`, and `GestureDetector`-unfocus wrapper, these stay in `HomeScreen` and are passed to `AppShell` as params.
- `build` returns `AppShell(...)` wrapping the `CustomScrollView` (inside the existing `CallbackShortcuts`/`FileDropArea`/`GestureDetector`).

### `SettingsStore` changes

Add persisted bool `sidebarCollapsed` (default `false`) with `toggleSidebarCollapsed()` / `setSidebarCollapsed(bool)`, following the existing persistence pattern (whatever `SettingsStore` uses, likely shared prefs / a persisted map).

### `AuthStore` / account

No changes. `AppTopBar` and `AppSidebar` footer read `AuthStore.currentUserName` (or equivalent) via provider.

## Data flow

```
HomeScreen (state: _query, _selection, _listMode, sort, searchController/Focus, semantic)
   │ passes callbacks + values down
   ▼
AppShell (responsive: sidebar|drawer + topbar + body)
   ├── AppTopBar   (search, account popover → Settings/Theme/SignOut, sort/layout)
   ├── AppSidebar  (wide)  ── uses ── AppNavContent
   └── Drawer(narrow)      ── uses ── AppNavContent
        │ onSelectView → HomeScreen._selectView
        │ onQuery       → HomeScreen._onQueryChanged
```

## Responsive behavior summary

| Width | Topbar | Sidebar | Drawer |
|---|---|---|---|
| `<600px` | hamburger + logo + search + sort/layout popup + account | none | yes (shared `AppNavContent`, expanded) |
| `>=600px` | logo (unless sidebar expanded) + search + sort/layout + account | persistent, expanded↔collapsible | no |
| `>=900px` | same | same | no (extra content padding stays in body) |

## Testing

- **`AppNavContent`**: widget test renders all destinations (Notes/Reminders/Archive/Trash) + label rows; tapping a destination calls `onSelect` with the right `ViewSelection`; `collapsed: true` renders icon-only.
- **`AppShell`**: widget test at `width < 600` renders a drawer + topbar (hamburger visible), no sidebar; at `width >= 600` renders sidebar + topbar (hamburger hidden), no drawer.
- **`AppSidebar`**: widget test that the collapse toggle flips `SettingsStore.sidebarCollapsed` and the rendered width changes (240 ↔ 56); expanded shows labels + label-edit row, collapsed hides them.
- **`AppTopBar`**: widget test that the search field calls `onQuery` on change; the account popover opens and shows Settings/Theme/Sign out; hamburger calls `onOpenDrawer`.
- **`HomeScreen`**: existing tests (if any) still pass; verify keyboard shortcuts still focus/clear search.

## Scope / non-goals

- No new logo asset, reuse `Icons.sticky_note_2_rounded`.
- `app_drawer.dart` is removed and replaced by `AppNavContent` + `AppSidebar` + the drawer usage inside `AppShell`.
- No change to `NotesStore`, `AuthStore`, `ViewSelection`, `NoteView`, or the editor screen.
- No change to grid column math or the `>=900` content padding (that stays in the body).
- Keyboard shortcuts (`/`, Cmd+K, N, Esc) keep working via `searchController`/`searchFocus` passed through `AppShell`.
- The `FileDropArea` web drop wrapper stays around the body (unchanged).

## Files

| Action | Path |
|---|---|
| New | `app/lib/widgets/app_shell.dart` |
| New | `app/lib/widgets/app_top_bar.dart` |
| New | `app/lib/widgets/app_sidebar.dart` |
| New | `app/lib/widgets/app_nav_content.dart` |
| Delete | `app/lib/widgets/app_drawer.dart` |
| Edit | `app/lib/screens/home_screen.dart` |
| Edit | `app/lib/state/settings_store.dart` (add `sidebarCollapsed`) |
