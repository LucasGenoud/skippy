# Skippy web client (Next.js)

A web-only client for Skippy, written to replace the Flutter web build where
it is slow. It talks to the same Rust API, with the same wire contract, and
reaches feature parity with the Flutter app on the web. The look may diverge
from Material: follow the design direction in "Design" below.

The Flutter source under `app/lib` is the specification. When this document
and the Flutter code disagree about behavior, the Flutter code wins; when they
disagree about structure, this document wins.

## Stack

- Next.js 16 (App Router) as a static export (`output: "export"`), React 19
  with the React compiler, TypeScript (strict, `noUncheckedIndexedAccess`).
- Tailwind CSS 4, shadcn/ui (Radix primitives via the `radix-ui` package),
  lucide icons, `motion` for animation, `sonner` for toasts.
- zustand for state (vanilla stores + selector hooks), idb-keyval for the
  offline cache, dnd-kit for drag and drop, react-markdown + remark-gfm +
  rehype-highlight for markdown, date-fns for dates, jszip for backups and the
  Keep import, @tanstack/react-virtual where a list can grow large.
- vitest + jsdom + @testing-library/react for tests.

Do not add dependencies. If one is truly needed, say so in your report
instead of installing it; several agents share one `package.json`.

## Commands (run in `web/`)

```sh
npm run typecheck     # tsc --noEmit
npm run lint          # eslint
npm test              # vitest run
npm run build         # next build --webpack -> out/
```

The build uses webpack because Turbopack needs to bind a local port, which
the sandbox refuses. Do not run `npm run build` or `npm run dev` from a
feature agent; typecheck, lint, and tests are enough. The integrator builds.

## Deployment

`next build` writes a static site to `web/out`. The Rust server serves it
when started with `WEB=../web/out`, exactly as it serves the Flutter build:
static files, unknown paths fall back to `index.html`, and when `PUBLIC_URL`
is set the server injects `window.stickyNotesApiBase = "<url>"` before
`</head>`.

Consequences:

- There is one HTML entry (`/`). Every app URL (`/n/<id>`, `/settings/ai`,
  `/s/<token>`, `/reset/<token>`) is served that same `index.html`, so routing
  is done on the client by `src/lib/router.ts`, not by Next route segments.
  Do not add `src/app/**/page.tsx` files.
- Nothing renders on the server. `src/app/page.tsx` mounts `<App />` from a
  `"use client"` module. Never read `window`/`localStorage` at module scope;
  do it in effects or in store initialisers called from the client.
- API base: `window.stickyNotesApiBase` if present, otherwise the server the
  user picked on the login screen, otherwise same origin.

## Directory layout and ownership

Each agent owns the paths listed for it and edits nothing else. If you need a
change in a path you do not own, describe it in your report.

```text
web/src/
  app/                 layout.tsx, page.tsx, globals.css        CORE (globals.css: DESIGN)
  lib/
    api/               wire types, Api interface, HttpApi, WS   CORE
    models/            domain types + parse/serialize           CORE
    state/             pure rules ported from app/lib/state     CORE
    store/             zustand stores (auth, notes, settings,   CORE
                       ui/navigation, link previews)
    util/              pure helpers ported from app/lib/util    CORE
    router.ts          client router                            CORE
    theme/             tokens, palette, accent, fonts, motion   DESIGN
  components/
    ui/                shadcn primitives, restyled              DESIGN
    common/            shared presentational widgets            DESIGN
  features/
    app/               App root, AuthGate, route outlet         CORE
    shell/             sidebar, top bar, search, shortcuts      SHELL
    notes/             grid/list, card, quick add, actions      NOTES
    editor/            note editor, history                     EDITOR
    board/             board view, stage editor                 BOARD
    reminders/         reminders view                           BOARD
    settings/          settings index and pages                 SETTINGS
    workspace/         workspace settings, stats, collections   SETTINGS
    auth/              login, register, reset                   AUTH
    chat/              notes chat                               AUTH
    public/            public share page                        AUTH
```

CORE creates every `features/<area>/index.ts` with the agreed exports below
as small placeholders, so the tree typechecks from day one. A feature agent
replaces its own placeholders; it keeps the export names and props.

### Feature entry points (stable contract)

| Module | Export | Props |
| --- | --- | --- |
| `features/shell` | `AppShell` | `{ children: ReactNode }` (renders sidebar + top bar around the active view) |
| `features/notes` | `NotesView` | `{}` (grid or list for the current navigation state) |
| `features/notes` | `NoteActionsMenu` | `{ noteId: string; surface: "card" \| "editor" }` |
| `features/editor` | `NoteEditor` | `{ noteId: string; onClose(): void }` |
| `features/editor` | `HistoryScreen` | `{ noteId: string; onClose(): void }` |
| `features/board` | `BoardView` | `{}` |
| `features/reminders` | `RemindersView` | `{}` |
| `features/settings` | `SettingsScreen` | `{ page?: SettingsPageId }` |
| `features/workspace` | `WorkspaceSettingsScreen` | `{ workspaceId: string }` |
| `features/workspace` | `WorkspaceStatsScreen` | `{ workspaceId: string }` |
| `features/auth` | `LoginScreen` | `{}` |
| `features/auth` | `ResetPasswordScreen` | `{ token: string }` |
| `features/chat` | `ChatScreen` | `{}` |
| `features/public` | `PublicShareScreen` | `{ token: string }` |

### Routes (`src/lib/router.ts`)

| Path | Renders |
| --- | --- |
| `/` | `AppShell` > view for the navigation state |
| `/n/<id>` | the same, plus `NoteEditor` over it |
| `/n/<id>/history` | the same, plus `HistoryScreen` |
| `/settings`, `/settings/<page>` | `SettingsScreen` |
| `/workspaces/<id>/settings` | `WorkspaceSettingsScreen` |
| `/workspaces/<id>/stats` | `WorkspaceStatsScreen` |
| `/chat` | `ChatScreen` |
| `/s/<hex>` | `PublicShareScreen` (no auth) |
| `/reset/<hex>` | `ResetPasswordScreen` (no auth) |

Navigation state that is not a page (active workspace, collection,
destination such as archive/trash/reminders/a label/a smart view, search
query, layout, selection) lives in the UI store, not the URL. The browser back
button closes an open note because opening one pushes `/n/<id>`.

## Architecture

### Stores (CORE)

Stores are vanilla zustand stores created per signed-in user, exposed through
React context plus selector hooks. Components subscribe to the smallest slice
they render (`useNote(id)`, `useVisibleNoteIds()`), never to the whole notes
map, so a keystroke in one note re-renders one card.

- `auth-store`: server URL, token, cached user; restore at startup; offline
  entry from cache when the server is unreachable (never a hard dependency on
  connectivity); login, register, logout, forgot/reset password, account
  update and delete.
- `notes-store`: port of `NotesStore` and its part files. Notes, workspaces,
  collections, labels, stages, smart views, sync issues. Every mutation is
  optimistic and enqueued as a serializable pending operation
  (`state/pending_operation.dart`), executed serially (create-before-update
  ordering), retried on transient failures (`sync_retry_policy.dart`), dropped
  on permanent client errors and recorded as a sync issue. The snapshot
  (notes, taxonomy, queue, sync issues) persists to IndexedDB per user
  (`notes_cache_doc.dart`, `local_cache.dart`). WebSocket events are change
  nudges: debounce, then refetch through the same snapshot path used by the
  initial load and manual refresh, rejecting stale snapshots by generation and
  local write revision. Starter notes after a new account's first load.
- `settings-store`: port of `SettingsStore`: defaults, JSON load/save to the
  opaque settings document (16 KB cap), managed settings and locks, secret
  redaction, `_ownManagedValues`, capabilities.
- `ui-store`: navigation state listed above, plus selection and transient UI
  flags shared across features (search focus request, layout).
- `link-preview-cache`: fetch coalescing for `/api/unfurl`.

### Pure modules (CORE)

Port these 1:1 from Dart with unit tests, keeping names close to the Dart
ones (camelCase): `note_collection`, `board_layout`, `note_conversion`,
`checklist_tree`, `note_links`, `sparse_position`, `reminder_agenda`,
`note_availability`, `starter_notes`, `bulk_import`, `workspace_reconciliation`,
`sync_retry_policy`, `editor_history`, util `search_query`, `linkify`,
`highlight`, `mime`, `note_export`, `keep_import`, `backup`, `network_error`,
`workspace_stats`, `label_style`.

### API (CORE)

`lib/api/client.ts` defines `interface Api` mirroring `app/lib/api/api_client.dart`
method for method, and `HttpApi` implementing it with `fetch`. Wire types in
`lib/models` mirror `backend/src/models.rs` and the Dart models, including
null-vs-omitted PATCH semantics (reminders), `depth` omitted at 0, and
`item_reminders` read-only on notes. `ApiError` carries status, server
message, and a plain-language summary (`network_error.dart`, `statusSummary`).
`changeEvents()` is a reconnecting WebSocket on `/api/ws`; `chat()` streams
frames from `/api/chat` with unknown-frame resilience. `tests/fake-api.ts`
is an in-memory `Api` for store tests (port of `app/test/fake_api.dart`).

## Design (DESIGN)

The result must look very good while staying simple. Build on the shadcn/ui
primitives wherever one fits (Dialog, Popover, DropdownMenu, Command, Tabs,
Switch, Calendar, Sheet, Tooltip, Sonner) and restyle through tokens and
variants, not one-off CSS. Aim for a polished, quiet look: generous spacing,
a clear type scale, restrained colour with the accent used sparingly, crisp
hover and focus states. Do not hand-build what the library already solves.

Move away from Material toward a crafted desktop feel (the user's reference
is Doska): one corner radius of 6px everywhere including tags and fields,
menus 8px; layered soft card shadows; no ink ripples; no pill or circle
controls; checked checkbox is an accent fill, checked text keeps its
strikethrough in grey; grey one-line descriptions in menus; a "Synced" pill;
calendar icon on date chips; progress ring plus count on checklist cards.

Colour system: port `app/lib/theme.dart` to CSS variables on `:root`/`.dark`.
Depth model: canvas (`surfaceDim`) is the ground, surfaces (`surface`) rise
for cards, chrome, dialogs, menus, toasts; troughs (`boardColumnColor`)
recess. Neutrals are the accent's hue at fixed low saturation, so changing
the accent retints the app (compute at runtime from the accent setting). The
accent has two roles: `primary` for text/icons needing contrast on a surface,
`primaryContainer` as a fill with `onPrimaryContainer` on it. Note colours
come from the palette (`palette_section.dart`), with light and dark variants.
The docked sidebar is a surface, never the canvas colour.

Motion: nothing snaps. Every appearance, removal, reorder and size change
animates, choosing the animation that fits (layout animation for reorders,
fade/scale for overlays, height for collapses). Shared durations and easings
live in `lib/theme/motion.ts` (port `util/motion.dart`).

Fonts: Inter, Lora, Nunito, JetBrains Mono from `app/assets/fonts`, loaded on
demand (`app_fonts.dart`).

## Performance rules

The reason this client exists. Every agent follows them.

- Subscribe narrowly. A card subscribes to its own note; lists subscribe to
  ordered id arrays compared shallowly. No component reads the whole store.
- Keep the editor's keystrokes local: the editor holds a draft and writes
  through the store debounced (as the Flutter editor does), never re-rendering
  the grid per key.
- Animate with transforms and opacity only; no animated layout properties on
  large lists. Masonry positions are computed in JS and applied as
  `transform: translate()`.
- Virtualise any list that can exceed a few hundred items.
- Code-split heavy, rarely used screens with `next/dynamic` or `React.lazy`
  (settings, chat, stats, history, markdown rendering, calendar, Keep import).
- Images: `loading="lazy"`, explicit aspect boxes so the masonry never
  reflows on load.
- No work at module scope; no synchronous IndexedDB/localStorage reads on the
  interaction path.

## Conventions

Follow the repository `AGENTS.md` code style (early return, named constants
for spec values, enums/string unions instead of boolean behaviour flags,
always-braced `if`, short comments that say what and why, private by default:
export only what another module uses). Components are function components in
`.tsx`, one exported component per file where practical, file names in
kebab-case. Plain text in docs, no emoji. Do not commit; the integrator does.

## Phases

1. CORE and DESIGN in parallel.
2. SHELL, NOTES, EDITOR, BOARD, SETTINGS, AUTH in parallel, each
   against the CORE store API documented in `web/docs/core-api.md`.
3. Integration: build, wire, fix seams, verify against the local
   backend in the browser, compare with the Flutter web build.

## Out of scope on the web (matches Flutter web)

Home-screen widgets, geofenced location reminders and the saved-places map,
share-sheet intake, camera source, on-device local notifications.
