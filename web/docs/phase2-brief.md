# Phase 2 brief (feature agents)

Six agents build the features in parallel in one checkout:
SHELL, NOTES, EDITOR, BOARD, SETTINGS, AUTH. Read, in order:

1. `web/PLAN.md` (binding: ownership, routes, entry points, performance).
2. `web/docs/core-api.md` (stores, hooks, router, models, Api). Code against
   it; read CORE source only when the doc is unclear.
3. `web/docs/design.md` (tokens, components, design principles). Use the
   shadcn primitives in `@/components/ui` and the shared widgets in
   `@/components/common` before writing anything new.
4. `AGENTS.md` at the repo root (contracts and code style).
5. The Flutter sources listed for your area. They are the specification:
   port the behavior, every feature and edge case, not just the happy path.

## Rules

- Edit only your own paths. Never edit `src/lib/**`, `src/components/**`,
  `src/app/**`, `package.json`, or another agent's feature folder. If you
  need a change there (a missing store action, a bug in CORE, a design
  token), work around it locally if it is small and say so in your report;
  otherwise list it in your report for the integrator.
- No new dependencies. No commits. No `npm run build`/`npm run dev`.
- Before finishing: `cd web && npm run typecheck && npm run lint && npm test`.
  Errors in other agents' in-progress folders are not yours; make sure none
  come from your paths (`npx tsc --noEmit 2>&1 | grep 'features/<area>'`).
- Add vitest + @testing-library/react tests for the rules your components
  own (keyboard handling, gestures that are decided in code, formatting).
- Design: very good looking, quiet, and simple. Lean on the component
  library; restyle through tokens and variants. Nothing snaps: every
  appearance, removal, reorder and resize animates (`motion`, constants from
  `@/lib/theme/motion`). Respect reduced motion.
- Performance (the reason this client exists): subscribe narrowly with the
  selector hooks; one note change re-renders one card; editor keystrokes stay
  local; animate transforms/opacity; virtualise long lists; lazy-load heavy,
  rarely used parts with `React.lazy`/`next/dynamic`.
- Web only: no home widgets, geofenced/place reminders, share intake,
  camera source, or on-device notifications.

## Shared cross-feature components

Some components are used by more than one feature. The owner creates each
file early, within its first few steps, with the final export name and props
and a minimal working body, then completes it. Consumers import from the
exact module path below (not the feature `index`) and code against these
props. If a consumer finishes before the owner, the import still resolves.

| Owner | Module | Export | Props |
| --- | --- | --- | --- |
| NOTES | `@/features/notes/note-card` | `NoteCard` | `{ noteId: string; variant: "grid" \| "list" \| "board"; dragHandleProps?: Record<string, unknown> }` |
| NOTES | `@/features/notes/note-markdown` | `NoteMarkdown` | `{ source: string; variant: "card" \| "editor"; onToggleTask?(lineIndex: number, done: boolean): void }` |
| NOTES | `@/features/notes/linked-text` | `LinkedText` | `{ text: string; highlight?: string; variant: "card" \| "editor" }` (linkified URLs and `[[id\|Title]]` note links) |
| NOTES | `@/features/notes/link-preview-card` | `LinkPreviewCard` | `{ noteId: string; url: string; variant: "card" \| "editor" }` |
| NOTES | `@/features/notes/audio-player` | `AudioPlayer` | `{ noteId: string; attachmentId: string; variant: "card" \| "editor" }` |
| NOTES | `@/features/notes` (index) | `NoteActionsMenu` | `{ noteId: string; surface: "card" \| "editor"; children?: ReactNode /* custom trigger */ }` |
| EDITOR | `@/features/editor/label-picker` | `NoteLabelPicker` | `{ noteIds: string[]; children: ReactNode /* trigger */ }` |
| EDITOR | `@/features/editor/share-dialog` | `ShareDialog` | `{ noteId: string; open: boolean; onOpenChange(open: boolean): void }` |
| EDITOR | `@/features/editor/public-link-dialog` | `PublicLinkDialog` | `{ noteId: string; open: boolean; onOpenChange(open: boolean): void }` |
| SETTINGS | `@/features/workspace/collection-settings-dialog` | `CollectionSettingsDialog` | `{ workspaceId: string; collectionId?: string /* absent = create */; open: boolean; onOpenChange(open: boolean): void }` |
| SETTINGS | `@/features/workspace/duplicate-workspace-dialog` | `DuplicateWorkspaceDialog` | `{ workspaceId: string; open: boolean; onOpenChange(open: boolean): void }` |
| SETTINGS | `@/features/workspace/workspace-dialogs` | `CreateWorkspaceDialog`, `RenameWorkspaceDialog` | `{ open; onOpenChange; workspaceId? }` |

## Who renders what

```text
App (CORE)
  AppShell (SHELL): sidebar/drawer, top bar, search, selection bar,
                    shortcuts, file drop/paste, archive/trash/label/smart
                    view headers and empty states
    NotesView (NOTES): quick add, pinned/others, masonry or list of NoteCard
    BoardView (BOARD): columns of NoteCard variant "board"
    RemindersView (BOARD): agenda + calendar
  NoteEditor overlay (EDITOR), HistoryScreen (EDITOR)
  SettingsScreen, WorkspaceSettingsScreen, WorkspaceStatsScreen (SETTINGS)
  LoginScreen, ResetPasswordScreen, PublicShareScreen, ChatScreen (AUTH)
```

Opening a note: `navigate({ name: "note", noteId })` (core-api.md section 7).
The editor owns the open/close animation.

## Report

When done, report: what is complete against the Flutter feature list for
your area (a checklist), what is partial or skipped and why, changes you
need from CORE/DESIGN/other agents, and the typecheck/lint/test summary.
