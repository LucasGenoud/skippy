# Motion and interaction audit, part A

Scope: `features/{app,shell,settings,workspace,auth,chat,public}`,
`components/**`, `lib/theme/**`, `app/globals.css`. Part B (MOTION-B) covers
`features/{notes,editor,board,reminders}`.

Every row is one animation or interaction-feedback detail of the Flutter
client, its web counterpart, and its status before this pass:

- matches: same idiom and timing (within the shared tokens).
- missing: Flutter animates it, the web had nothing.
- snaps: the web changed it between two frames.
- timing: animated, but with the wrong duration, curve or overlap.
- n/a: no web counterpart by design, or owned by part B.

"Fixed" in the last column means this pass changed it.

## Summary

| Status before | Count |
| --- | --- |
| matches | 54 |
| missing | 7 |
| snaps | 24 |
| timing | 3 |
| n/a | 5 |

All 34 gaps (missing, snaps, timing) in scope are fixed. The note editor's
own side of the route exit is MOTION-B's; see "Contract for MOTION-B".

## App root and routes (`main.dart`, `theme.dart`, `MaterialPageRoute`)

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| `AnimatedSwitcher` (slow, standard) over the auth status: splash, login, home | `AuthGate` in `features/app/app.tsx` | snaps | Fixed: `GateFade` fades the next screen in over SLOW. No exit: a signed-out session's stores are already disposed. |
| `MaterialApp` `AnimatedTheme` on theme or accent change | `ThemeSync` | snaps | Fixed: `fadeTheme` (lib/theme/accent.ts) runs the change through the View Transitions API, one page-wide cross-fade over BASE; instant where unsupported or reduced. |
| `MaterialPageRoute` push/pop for settings, workspace settings, statistics, chat | `RouteOutlet` replaced the home view with the page | snaps | Fixed: `PageOutlet` (features/app/page-outlet.tsx) slides the page 24px in while fading (BASE, emphasized) and out (FAST); `PAGE`/`pageVariants` in lib/theme/motion.ts. |
| The home route stays mounted under a pushed page (scroll, search, selection kept) | Home unmounted on every page | missing | Fixed: home is always mounted; `inert` while a page is up, `visibility: hidden` once it has fully arrived, visible again as it leaves. |
| Focus returns to the control that opened a page | Focus fell to `<body>` | missing | Fixed: `useHomeFocusReturn` refocuses the last focused home control when a page closes. |
| Popping an overlay route (`/n/<id>`, history) with the system back plays its reverse transition | The outlet unmounted the overlay in one frame | snaps | Fixed on the outlet side: `OverlayOutlet` keeps the overlay mounted with `present: false` until it releases itself. Editor side: MOTION-B. |
| Pages are built before the transition starts | `Suspense fallback={null}` could show an empty layer, then pop the page in | snaps | Fixed: an opaque surface fallback inside the page layer, and the lazy pages are fetched 2s after sign-in. |
| `NoSplash`, hover veil 6%, highlight 10% | Button, menu item and row veils (`hover:bg-hover`, `active:bg-pressed`, 150ms) | matches | |
| `Motion.menu` (BASE emphasized in, FAST standard out) | `floatingMotion` on menus, popovers, selects | matches | |
| Dialog and sheet enter/exit | `DialogContent`, `AlertDialog`, `Sheet` (240 in, 150 out) | matches | |
| Snack bar enter/exit (~250ms) | sonner, 400ms default | timing | Fixed: globals.css puts toasts on BASE, emphasized. |
| Reduce motion | `MotionConfig reducedMotion="user"`, `transitionFor`, globals.css collapse | matches | New code gates on `useReducedMotion`. |
| Grid / board / agenda swap (no switcher in Flutter) | `ActiveView` | snaps | Improved: the new kind fades in over BASE (`ActiveView` in signed-in-app.tsx). The grid's own view, collection and workspace cross-fade is inside `NotesView` (n/a, part B). |

## Home scaffold (`home_screen.dart`, `home_top_bar.dart`, `home_fabs.dart`, `app_drawer.dart`)

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| `_selectView`: a new view jumps to the top; the same view glides up (SLOW, emphasized) | `useOpenDestination` | matches | |
| Offline banner `AnimatedSize` + `AnimatedSwitcher` | `OfflineBanner` | matches | |
| Offline Retry: fade+scale swap to a spinner | `OfflineBanner` Retry | snaps | Fixed: `CrossFade`, centred. |
| Grid view switch `AnimatedSwitcher` keyed by view/collection/workspace | `NotesView` | n/a | Part B. |
| Skeletons while loading | `NotesSkeleton` via `NotesView` | n/a | Part B. |
| Empty state replaced by the first card | `ViewEmptyState` returned null in one frame | snaps | Fixed: fades out (FAST) lifted out of the flow (`popLayout`); the scroll root is now `relative` for it. |
| `EmptyState` fade + rise (SLOW) | `components/common/empty-state.tsx` | matches | |
| Selection bar in / browsing bar out (one switcher, browsing fades in on 0.4-1) | `TopBar` | matches | |
| View title cross-fade (BASE) | `WideBar` title | matches | |
| Chat button `AnimatedPresence` | Wide bar | matches | |
| Chat button on the phone bar | `CompactBar` | snaps | Fixed: fade+scale presence. |
| Grid/list icon swap (`_fadeScale`) | `LayoutToggle` icon | matches | |
| Grid/list button leaving on a board or agenda | `LayoutToggle` returned null | snaps | Fixed: fade+scale presence. |
| Theme toggle icon | `ThemeToggle` rotate-fade | matches | |
| Search pill lifts on focus (`AnimatedContainer` FAST) | `SearchField` | matches | |
| Search controls appear on focus | `SearchField` presence | matches | |
| Sync badge spin on the avatar | `SyncBadge` | matches | |
| FAB menu open/close (BASE in, FAST out), hover lift 1.06 | `HomeFabs` | matches | |
| Sidebar width `AnimatedContainer` (BASE, emphasized) | `ShellFrame` aside | matches | |
| Section headers fade when collapsing | `SectionHeader` | matches | |
| Row selection fill and marker fade (FAST) | `SidebarRow` | matches | |
| Rail tooltips | `SidebarRow` compact | matches | |
| Drawer: `_afterDrawer` waits SLOW before showing a dialog or page | Dialog opened while the drawer was still closing | timing | Fixed: `after()` in `SidebarContent` and `WorkspaceMenu.beforeAction` wait BASE (0 under reduced motion). |
| Drawer slide | `Sheet side="left"` | matches | |
| Window file drop overlay | `FileDropOverlay` | matches | |
| Sync pill: `AnimatedContainer` colours + `AnimatedSize` (BASE) + `AnimatedSwitcher` | `SyncPill` | snaps | Fixed: width now tweens (`TweenWidth`, BASE emphasized); the label already cross-faded. |
| Rolling count | `RollingCount` | matches | |

## Shell dialogs and sheets

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| Labels sheet rows `StaggeredEntrance` | `LabelsDialog` | missing | Fixed: `components/common/staggered-entrance.tsx` (28ms step, 200ms cap, 6px rise); `SortableRows entrance="staggered"`. |
| Smart views rows `StaggeredEntrance` | `SmartViewsDialog` | missing | Fixed, same. |
| Removing a label or smart view from the list | Row removed in one frame | snaps | Fixed: the row folds (height + fade, BASE). |
| Label picker "+" to check pop | `PickRow` check (bulk pickers) | snaps | Fixed: scale+fade pop on `ease-back`. |
| Filter chip colour tween, label `AnimatedSize` + switcher | `FilterChip` (`layout="size"`, `CrossFade`) | matches | |
| Filter chip check / ban icon | `FilterChip` | snaps | Fixed: popped in and out (`TRANSITION.pop`). |
| `GlyphBadge` colour while editing | `GlyphBadge` | snaps | Fixed: colours transition (FAST). |
| Field hint giving way to an error | `TextField` | snaps | Fixed: the hint folds with `Reveal` as the error grows. |
| `FormErrorBanner` / `AnimatedReveal` | `AnimatedFormError`, `Reveal` | matches | |
| Shortcut help | dialog primitive | matches | |
| Saved view dialog, label editor | dialog primitive + `Reveal` | matches | |
| Workspace menu | `DropdownMenu` | matches | |

## Settings (`settings_screen.dart`, `widgets/settings/*`)

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| Phone: a page is pushed over the index (`MaterialPageRoute`) | `SettingsScreen` swapped index and page | snaps | Fixed: `PhoneStack` pushes the page with `PAGE` variants; the index stays mounted (inert) underneath. |
| App bar title change on the phone | `<h1>` | snaps | Fixed: `CrossFade`. |
| Wide: `StateCrossFade` between pages, both in one slot | `PageView` `mode="wait"` (out, then in) | timing | Fixed: overlapping cross-fade in one grid cell. |
| Index row selection fill fades (FAST) | `WideIndex` | matches | |
| Probe rows, embedding stats, export progress | `probe-row`, `embedding-stats`, `export-section` | matches | |
| Revocable lists grow and fold | `RevocableList` | matches | |
| Revoking a token or link: no feedback until it is gone | `DenseRow` | missing | Fixed: `state="pending"` dims the row and holds its actions. |
| Creating a token: no feedback until the dialog | "New token" button | missing | Fixed: spinner cross-fade, disabled while in flight. |
| Grid layout preview | `grid-layout.tsx` | matches | |
| Accent and palette pickers | `accent-color`, `palette-section` | matches | |

## Workspace (`workspace_settings_screen.dart`, `workspace_stats_screen.dart`, `collection_settings.dart`, `duplicate_workspace_dialog.dart`, `workspace_ai_section.dart`)

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| Delete: wait for the dialog's dismissal, then delete and pop | Closed the page and deleted at once; the leaving page flashed "This workspace is gone." | snaps | Fixed: `useLeavingWorkspace` keeps the last workspace on screen while its page leaves. |
| Leave workspace, remove yourself | same | snaps | Fixed, same hook. |
| Stats rows `StaggeredEntrance`, bars tween (BASE) | `workspace-stats-screen`, `stats-charts` | matches | |
| Duplicate dialog `AnimatedReveal` | `DuplicateWorkspaceDialog` | matches | |
| Collection settings two-pane list with stagger and `StateCrossFade` | `CollectionSettingsDialog` is one collection's form | n/a | Different structure by design. |
| Collection header glyph `AnimatedContainer` | `GlyphPicker` preview | matches | |
| Workspace AI switches | `Switch` primitive | matches | |

## Auth, chat, public share

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| Login frame entrance | `AuthFrame` fade + rise | matches | |
| Login `AnimatedSize` for the extra fields | `Reveal` per field | matches | |
| Login tab switch | `Tabs` (fill fades, FAST) | matches | |
| Submit label and icon swap on tab switch and busy | `Button` content | snaps | Fixed: one centred `CrossFade`. |
| Forgot password, server URL dialogs (`AnimatedSize`) | `auto-height`, `Reveal` | matches | |
| Reset password `AnimatedSize` + switcher | `ResetPasswordScreen` | matches | |
| Chat message entrance (BASE, emphasized) | `ChatBubble` | matches | |
| Chat sources / written-note chips `_reveal` | `Reveal` | matches | |
| Typing dots | `TypingDots` | matches | |
| Interrupted / Stopped line | `ChatBubble` | snaps | Fixed: `Reveal`. |
| Undo chip: undoing / undone | `ChatBubble` | snaps | Fixed: `CrossFade`. |
| New conversation clears the log | log cut to the hint | snaps | Fixed: the log fades out (FAST) as the hint settles in. |
| Send / stop swap | `ChatComposer` `CrossFade` | matches | |
| Public share `StateCrossFade` loading to page | `PublicShareScreen` | matches | |
| Public share images `Motion.fadeInFrame` | `public-note-card` image fade | matches | |

## Components (`components/**`)

| Flutter | Web | Before | After |
| --- | --- | --- | --- |
| `AnimatedPresence` / `AnimatedReveal` | `Reveal` | matches | |
| `StateCrossFade` | `CrossFade` | matches | |
| `StaggeredEntrance` | none | missing | Fixed: `StaggeredEntrance`. |
| `RollingCount`, `Skeleton` pulse, `PageHeader` subtitle switcher | same names | matches | |
| `AllDoneBurst` (celebration) | `AllDoneBurst` | n/a | Part B uses it. |
| `DeferredBuild` | none | n/a | No equivalent need on the web. |
| Tooltips on icon-only buttons | `IconButton` (label = tooltip + name) | matches | Every icon-only button in scope has a tooltip or a visible label. |
| Focus-visible ring on every control | primitives and hand-built buttons | matches | |
| Disabled states | primitives `disabled:opacity-50` | matches | |

## Desktop pass

The app is desktop-browser first; phone layouts keep working. In scope:

| Area | Change |
| --- | --- |
| Shortcut discoverability | Removed later: key chips in fields, tooltips and menus have no Flutter counterpart. The shortcuts still work, and the reference lists them (`?`, or Settings, About). |
| Escape on pages | Settings, workspace settings and statistics, and chat go back on Escape, through each page's own Back button (a phone settings page returns to its index), unless a text field, dialog or menu has the key. The shortcut reference lists it. |
| Right-click | Removed later with the sidebar's hover pencils: collections, labels and smart views are managed from their "Manage" rows, as in Flutter. |
| Keyboard | Up/Down walk the unfolded new-note menu; focus returns to the opening control when a page closes. |
| Hover and tooltips | The sync pill has a hover state and a tooltip. Every icon-only control in scope has a tooltip naming it. |
| Not added | `Cmd ,` for settings: the browser takes it on macOS before the page sees it. |

## Contract for MOTION-B

As implemented. The route outlet (`features/app/overlay-outlet.tsx`) keeps a
routed overlay mounted after its route has gone, until the overlay reports
that its exit has finished. It applies to the overlays for `/n/<id>`
(`NoteEditor`) and `/n/<id>/history` (`HistoryScreen`). The hook's API is
fixed:

```ts
import { useOverlayPresence } from "@/components/common/overlay-presence";

const { present, safeToRemove } = useOverlayPresence();
```

- `present` is true while the route still shows this overlay. It turns false
  when the route leaves it: browser back, a link, or the overlay's own
  `onClose` (which navigates).
- `safeToRemove()` releases the slot. It is idempotent and does nothing while
  `present` is true. The outlet hands the real release only to the leaving
  render, so an overlay cannot remove itself while its route is current.
- The hook registers the overlay in a layout effect. It is called
  unconditionally at the top of the component. An overlay that never calls it
  is removed as soon as its route goes.
- Safety net: an overlay that is no longer present and never releases is
  removed after `EXIT_TIMEOUT_MS` (1000ms, `lib/theme/motion.ts`).
- While leaving, the overlay keeps the props of its last current render; its
  stores keep updating it.
- Reopening the same overlay while it is leaving drops the leaving instance
  and mounts a fresh one. A different overlay mounts beside the leaving one
  (note to history: the editor closes while history arrives).
- Outside an outlet (tests), the hook reports always present.

How the two overlays use it:

- `NoteEditor`: Escape, the close button and a tap outside call
  `requestClose`, which plays the close morph (shrink back into the card)
  once, through a shared `playClose()` promise. If the route is still
  current when it ends, it calls `onClose()`; the route then leaves and the
  editor, already closed, releases. If the route left first (browser back),
  an effect on `present` plays the same morph and then calls
  `safeToRemove()`. The draft is finalized as the editor unmounts, after the
  release. Radix restores focus on that unmount.
- `HistoryScreen`: Back, Escape and a restore go through one `close()`
  that calls `onClose()` once. The page animates with the shared `PAGE`
  variants (`pageVariants`); when `present` turns false it switches to
  `leave`, ignores pointer input, and calls `safeToRemove()` from
  `onAnimationComplete("leave")`, or at once under reduced motion.

Possible later step: Flutter keeps the editor mounted under history. That
needs `HistoryScreen` to be a modal layer of its own (for example a Radix
dialog), so that pointer events and focus outside the editor do not close it.
If that lands, the outlet can keep the editor present under
`/n/<id>/history`.

## Not done

- The grid's skeleton-to-cards, card, editor, board and reminders motion is
  part B's.
- Font changes (`loadFont`) still reflow in one step once the faces load; a
  cross-fade there would hide the very text the user is reading.
