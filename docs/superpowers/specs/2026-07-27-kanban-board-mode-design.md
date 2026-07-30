# Kanban Board Mode, Design and Estimate

**Date:** 2026-07-27
**Status:** v1 implemented. Drag (phase 6) deferred; see "What shipped".

## What shipped

A first version, built to the recommendations in this document with **drag
deliberately left out**, cards move via "Move to column" in the card menu,
which was always meant to be the guaranteed and accessible path. That keeps the
fragile gesture work (phase 6) cleanly separable and decidable after the board
has been lived in.

Q1-Q7 were answered as recommended below, with one adjustment: intra-column
ordering is carried by `stage_position` but has no UI yet, since there is no
drag to reorder with. New cards append to the end of their column.

Deferred, in the order worth reconsidering:

- Cross-column and intra-column **drag** (phase 6), plus the midpoint/repair
  ordering machinery. `stage_position` already exists to receive it.
- Column **reordering** in the UI. The field, the API, and the store method are
  all in place; only the drag affordance is missing.
- The one-shot **"create stages from labels"** import (see Deferred, below),
  which is the mitigation for the adoption gap.
- Stage round-tripping through **zip backups**. A restored note lands
  unassigned.

## Goal

A board view where each column is a **stage** and every note sits in at most one
stage. Dragging a card between columns changes the note's stage. The board must
be genuinely usable on a phone, not a desktop feature with a degraded mobile
fallback.

## The model

Stages are their own system, deliberately **independent of labels**:

| | Labels | Stages |
|---|---|---|
| Relationship to a note | many-to-many via `note_labels` | one-to-one via `notes.stage_id` |
| Purpose | cross-cutting taxonomy | position in a pipeline |
| Exclusive? | no | yes, enforced by the schema |

An earlier draft derived columns from labels. It was rejected: labels are a set
and columns are exclusive, so it required a client-side "first column wins"
heuristic over a many-to-many table, an invariant nothing enforced, which the
add-only auto-labeler ([`background.rs:107`](../../../backend/src/handlers/background.rs))
would actively violate by unioning new labels onto a note in the background.
A dedicated `stage_id` makes exclusivity a schema fact and deletes that entire
problem class.

The cost is a new workspace-scoped entity plus a persisted note field, both
prescribed change paths in `AGENTS.md` with explicit checklists. That trade is
the point: prescribed CRUD is cheap to write and maintain; novel invariants
enforced only by discipline are not.

### Independence rules

These are load-bearing. The two systems look alike, and the main risk to
simplicity is someone unifying them into a generic "workspace taxonomy" module
later.

- **No shared abstraction.** `handlers/stages.rs` will read as a near-copy of
  `handlers/labels.rs` (111 lines), same member-scoped permissions, same
  `notify_workspace` fan-out. Accept the duplication. Two small files that each
  do one obvious thing beat one generic file with a discriminator.
- **No foreign key, no shared table, no shared join.** Deleting a label never
  touches stages; deleting a stage never touches labels.
- **No implicit writes.** A note patch carrying `stage_id` must not write
  `note_labels`, and one carrying `label_ids` must not write `stage_id`. One
  explicit test each, this is the kind of thing that regresses quietly.
- **Separate client types.** A `Stage` model, its own store list, its own editor
  dialog. `buildBoard` takes stages and notes, never labels.
- **Shared code is allowed only over primitives.**
  [`label_style.dart`](../../../app/lib/util/label_style.dart) is already
  factored correctly: `labelIconFor(String?)` and `PaletteEntry.hexToColor(String?)`
  take primitives, and only the thin `labelIcon(Label)` wrappers are typed.
  Stages call the primitive functions. Sharing a pure function over a hex string
  is not coupling.

Stages carry **name + colour, no icon.** Column headers are text-led, a glyph
per column is noise, and it reinforces that stages are not "labels 2".

## Open questions

These block implementation. Each has a recommendation, but the call is the
owner's.

**Q1. Does every note appear on the board, or only staged ones?**
An "Unassigned" column that holds every unstaged note means a workspace with 500
notes opens the board on a 500-card column, worst on a phone, where that column
is the whole screen. Options: (a) all notes, Unassigned first; (b) only notes
explicitly added to the board, with Unassigned absent; (c) all notes, but
Unassigned is capped at ~20 with a "show all" and is not the landing column.
*Recommendation: (c).* It keeps the board a complete view of the workspace
without making the inbox the first thing you fight.

**Q2. One board per workspace, or several named boards?**
Multiple boards means stages belong to a board, not a workspace, and adds a
board picker. *Recommendation: one per workspace.* People who want a second
board can make a second workspace, which already exists and already scopes
everything correctly.

**Q3. Mobile cross-stage gesture: drop-on-strip only, or also swipe-to-advance?**
Swiping a card left/right to move it one stage along is lovely for a pipeline
but nests a horizontal gesture inside a horizontally-paging `PageView`, which is
a known source of gesture-arena pain. *Recommendation: ship drop-on-strip plus
the move sheet; treat swipe-to-advance as a separate experiment.*

**Q4. Does the board honour `SortMode`, or always use `stage_position`?**
If a user's global sort is "edited", does the board ignore their manual card
order? *Recommendation: the board always orders by `stage_position` and hides
the sort control while it is open.* A board whose cards reshuffle themselves is
not a board.

**Q5. What happens to a non-empty stage on delete?**
Options: block the delete, require choosing a destination stage, or send its
notes to Unassigned. *Recommendation: send to Unassigned with an undo snack.*
This is intentionally less destructive than workspace deletion, which
permanently deletes every note the workspace contains.

**Q6. Can the stage be changed from the note editor?**
A stage chip in the editor bottom bar is the obvious place, but it is extra
scope and another surface to keep in sync. *Recommendation: yes, read-write
chip*, a card you opened to work on is exactly when you want to advance it.

**Q7. Should a terminal stage optionally archive its notes?**
"Done" auto-archiving after N days keeps the board from growing forever.
*Recommendation: not in v1*, but decide now whether stages need a `terminal`
flag reserved in the schema.

## Data model

```sql
CREATE TABLE IF NOT EXISTS stages (
    id           TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    color        TEXT,
    position     REAL NOT NULL
);
```

Plus two additive columns on `notes`, appended to `ADDITIVE_MIGRATIONS` in
[`sqlite_schema.rs`](../../../backend/src/store/sqlite_schema.rs) alongside the
existing seven:

```
ALTER TABLE notes ADD COLUMN stage_id TEXT
ALTER TABLE notes ADD COLUMN stage_position REAL
```

`stage_id` is nullable, null means Unassigned.

**Backfill.** `ADDITIVE_MIGRATIONS` re-runs every statement on every startup and
discards errors (`apply_additive_migrations`), so it is DDL-only. The
`stage_position` seed belongs as its own idempotent step next to
`migrate_user_accounts`, guarded exactly the way that one is:

```sql
UPDATE notes SET stage_position = position WHERE stage_position IS NULL
```

Safe to re-run, seeds every board in the order people already arranged their
grid, and means `stage_position` is *always set*, no null handling in the sort,
the decoder, or the Dart model.

**Invariant:** a note's stage must belong to the note's workspace. There is
already a template, `PRUNE_MISMATCHED_LABELS` in
[`sqlite.rs:30`](../../../backend/src/store/sqlite.rs), and `moveNoteToWorkspace`
already drops foreign labels, so the workspace-move path clears `stage_id` by
the same rule, via a separate guard.

## API

`/api/stages` CRUD, parallel to `/api/labels`: any workspace member may create,
rename, restyle, reorder, or delete, and every change notifies the whole roster.

`stage_id` and `stage_position` join the note create/update payloads. Both are
**organization-only** state: per the mutation-side-effects rule in `AGENTS.md`,
setting them must not trigger version capture, semantic reindexing,
auto-labeling, or collaborator notification. Same class as pin, archive, colour.

### Ordering: one patch per move

`stage_position` is sparse. The client computes the midpoint between the two
cards it was dropped between and sends a single patch:

```
PATCH /api/notes/{id}   {"stage_id": "...", "stage_position": 3584.0}
```

A cross-stage move and an intra-stage reposition are therefore *the same
operation*, one row written, one queued op, works offline through the existing
queue unchanged. This is the same trick the create path already uses:
`_frontPosition()` returns `min - 1024.0`
([`notes_store.dart:772`](../../../app/lib/state/notes_store.dart)).

The alternative, renumbering the whole board on every drop, would write N rows
per drag and couple board order to the grid's custom `position`. A separate
field avoids both.

**Repair path.** Repeated midpoints into one gap eventually exhaust float
precision. When a gap falls below an epsilon, the client renumbers that stage
and calls the existing `POST /api/notes/reorder`, which gains an optional
`stage_id`: present means write `stage_position`, absent means the current
global behaviour. Note the persisted-queue detail, the reorder `PendingOp`
carries `data: {'ids': [...]}` today, and adding an optional key stays readable
by queues written by older builds.

## Client architecture

- `NoteView.board` joins the enum in `note_collection.dart`, with a **Board**
  entry in the sidebar. Not a third state of the grid/list toggle: the board is
  incompatible with Trash, Archive, Reminders and label views, and has its own
  drag rules, empty state and compose target. A `ViewSelection` keeps every
  existing `switch (selection.view)` exhaustive.
- `state/board_layout.dart`: a pure `buildBoard({notes, stages, scope, query})`
  returning ordered columns. Groups by `stage_id`, sorts by `stage_position`.
  No heuristics left to encode. Pure, so it tests without a widget tree.
- `NotesStore` gains a stages list, stage CRUD passthrough, and
  `setNoteStage(noteId, stageId, position)` issuing one `_patch`, following
  `moveNoteToWorkspace` ([`notes_store.dart:1289`](../../../app/lib/state/notes_store.dart)),
  not a pair of calls that would enqueue two ops for one gesture.

**One column widget, two containers.** A column is a vertical list of cards with
drag-reorder, identical on every platform. Only the container around it and the
cross-stage affordance differ. Build the column once.

Reuse `AnimatedMasonry` at `columns: 1` for it: it already gives measured
heights, glide-on-reflow, long-press touch drag, edge auto-scroll, entrance
stagger, and the tile caching that exists because note cards are expensive to
build ([`masonry.dart:90`](../../../app/lib/widgets/masonry.dart)), which
matters more here, since a board mounts more cards at once than a grid does.

## Mobile

The phone is a first-class target, and it drives the layout more than the
desktop does.

- **Container:** a `PageView` of stages, one per screen, swiped horizontally.
- **Header:** a horizontally scrollable stage strip (~44px) showing name +
  card count, current stage highlighted, tap to jump.
- **Reorder within a stage:** long-press drag, vertically, inside the visible
  column. This already works, masonry's touch path is a `LongPressDraggable`
  with a 220ms delay ([`masonry.dart:404`](../../../app/lib/widgets/masonry.dart)),
  chosen so scrolling wins the gesture arena.
- **Move across stages (primary gesture):** long-press lifts the card, and the
  **stage strip becomes drop targets**, drag up, drop on a stage chip. The drag
  is short, no page has to turn under the user's finger, and because it starts
  from a long press the `PageView` never claims the gesture. It reuses the exact
  `DragTarget<String>` note-id protocol the sidebar already uses
  ([`app_drawer.dart:392`](../../../app/lib/widgets/app_drawer.dart)).
- **Move across stages (guaranteed path):** a **Move to…** item in the card
  menu opening a bottom sheet of stages. Always available, one tap plus one tap,
  and the accessibility path on every platform.
- **Explicitly not doing:** dragging a card across pages with auto-page-turn.
  It is the fragile, expensive option and it fights the `PageView`.
- **Creating:** the FAB and quick-add compose into the currently visible stage,
  reusing the `labelIds`-style pre-fill path that already backs label views.

Vertical budget is tight: top bar plus stage strip, and the board takes the
rest. The board must not nest inside the home `CustomScrollView`, it is a
horizontal container of independently scrolling columns, so `HomeScreen`
branches above the sliver stack.

`isTouchPrimaryPlatform` ([`util/platform.dart`](../../../app/lib/util/platform.dart))
already distinguishes finger-primary from pointer-primary and is what masonry
branches on today; the board uses the same signal, with width deciding paged
versus side-by-side.

## Desktop and tablet

- **>= 900px:** all columns side by side, horizontal scroll, fixed ~300px width.
- **600–900px:** same with narrower columns.
- **< 600px:** the paged board above.

Pointer drag is instant (no long press), matching masonry's existing pointer
path, with cross-column drag and horizontal edge auto-scroll while dragging.

## Implementation phases

| Phase | Work | Effort |
|---|---|---|
| 0 | Answer Q1–Q7 | 0.5 d |
| 1 | Backend: schema, backfill, repo, `handlers/stages.rs`, routes, note payload fields, org-only classification, API tests | 2–2.5 d |
| 2 | Client contract: `Stage` model, `Note` fields, `ApiClient`, `FakeApi`, store CRUD + `setNoteStage` | 1 d |
| 3 | `board_layout.dart` + tests | 0.5 d |
| 4 | Column widget + desktop board shell, `NoteView.board`, sidebar entry, empty states | 1.5–2 d |
| 5 | Mobile board: `PageView`, stage strip, drop-on-chip, move sheet | 1.5–2 d |
| 6 | Drag polish: cross-column, two-axis auto-scroll, midpoint + repair path | 1.5–2 d |
| 7 | Editor stage chip, search within board, docs (README + `AGENTS.md`) | 1 d |

**Total: 10–12 days**, one developer, tests and docs included, at this repo's
quality bar.

Reduced scope, move via sheet and stage-strip tap only, no drag anywhere, is
**6–7 days** and still yields a board usable on both phone and desktop. Phase 6
is the separable one; it can be decided after the board has been lived in.

## Files touched

**New, backend:** `handlers/stages.rs`, `tests/api/stages.rs`.
**Changed, backend:** `models.rs`, `store/mod.rs`, `store/sqlite.rs`,
`store/sqlite_schema.rs`, `store/sqlite_rows.rs`, `handlers/mod.rs`,
`handlers/notes.rs`, `lib.rs`, `tests/api/notes.rs`.

**New, client:** `state/board_layout.dart`, `widgets/board/board_view.dart`,
`board_column.dart`, `board_stage_strip.dart`, `board_page_view.dart`,
`stage_editor_dialog.dart`, `move_to_stage_sheet.dart`,
`test/board_test.dart`, `test/board_widget_test.dart`.
**Changed, client:** `models/note.dart`, `api/api_client.dart`,
`state/notes_store.dart`, `state/note_collection.dart`,
`screens/home_screen.dart`, `screens/editor_screen.dart`,
`widgets/masonry.dart`, `widgets/app_drawer.dart`, `widgets/note_card.dart`,
`widgets/home_top_bar.dart`, `test/fake_api.dart`,
`test/notes_store_test.dart`, `README.md`, `AGENTS.md`.

## Risks

1. **Mobile gesture arena.** Long-press-drag inside a `PageView` inside the
   app's existing scroll and drawer gestures. The drop-on-strip design avoids
   the worst case, but this is where the phone build will fight back.
2. **Render cost.** A board mounts every card in every visible column. Keep
   masonry's tile caching and `RepaintBoundary`s; consider per-column culling,
   which the grid deliberately skips but a ten-column board cannot.
3. **A second scroll topology in `HomeScreen`.** A 1,094-line file that
   `AGENTS.md` already calls a coordinator gains a branch that bypasses its
   sliver stack.
4. **Unassigned overflow** (Q1). Unbounded on day one in a mature workspace.
5. **Adoption gap.** People already organising with `todo`/`doing`/`done` labels
   get nothing until they recreate those as stages, see below.

## Deferred

- **One-shot "create stages from labels"** in the board's empty state: pick
  labels, copy their names into stages, optionally assign each note by its
  current label, then never read labels again. A one-time import on explicit
  user action creates no ongoing coupling, nothing in the running system
  consults labels afterward. This is the mitigation for risk 5 and is worth
  doing early if adoption matters.
- WIP limits per stage.
- Swimlanes.
- Terminal-stage auto-archive (Q7).
- Multiple boards per workspace (Q2).
