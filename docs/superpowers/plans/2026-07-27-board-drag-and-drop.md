# Board Drag and Drop — Implementation Plan

**Date:** 2026-07-27
**Status:** Ready to implement
**Follows:** [Kanban Board Mode design](../specs/2026-07-27-kanban-board-mode-design.md), v1 shipped on `feat/kanban-board`

## What changed since the design doc

The design doc costed this phase at 2–3 days and called it the riskiest part,
assuming a shared drag session coordinating ghost and gap across sibling
widgets. Reading the shipped code, it is smaller than that. Two findings:

**1. Masonry's internal reorder needs no changes at all.** `AnimatedMasonry` is
already a self-contained drag engine: `_reorderToPointer` reflows around the
pointer, `_onDragEnd` reports the new order
([masonry.dart:279](../../../app/lib/widgets/masonry.dart)), and tiles are
already `Draggable<String>` / `LongPressDraggable<String>` carrying the note id.
Point a column at it with `columns: 1` and intra-column reordering works.

The only addition is making a column a `DragTarget<String>` for ids it does
*not* own. Intra-column and cross-column then stay separate paths that never
have to know about each other:

| Drop | Handled by | Result |
|---|---|---|
| Inside the same column | masonry's existing `onReorder` | reposition |
| On a different column | that column's new `DragTarget` | move + position |

No shared drag session, no cross-instance ghost coordination.

**2. Both paths collapse into one store call.** Because v1 already carries
`stage_position`, a reposition is just a move to the stage the card is already
in. With midpoint positioning, both are a single patch:

```dart
store.setNoteStage(noteId, stageId, position: midpointBetween(above, below));
```

So there is one mutation to write and one to test, not two.

## The work

### 1. Store: positioned moves (~0.5 d)

`setNoteStage(noteId, stageId)` currently appends to the end of the target
column. Give it an optional explicit position:

```dart
void setNoteStage(String noteId, String? stageId, {double? position})
```

Absent keeps today's append behaviour, which the "Move to column" sheet relies
on. Add a pure helper next to it:

```dart
/// Midpoint between the cards a drop landed between; `null` neighbours mean
/// the head or tail of the column.
double positionBetween(Note? above, Note? below)
```

Head is `below.stagePosition - 1024`, tail is `above.stagePosition + 1024`,
between is the mean. This mirrors `_frontPosition()`
([notes_store.dart:772](../../../app/lib/state/notes_store.dart)), which
already does sparse float positioning for note creation.

Tests: reposition within a column is one patch; a move carries both fields;
head/tail/between all land in the right order; an offline move survives a
restart (extend the existing stage queue test).

### 2. Columns render through masonry (~0.5 d)

Swap `board_column_view.dart`'s `ListView.builder` for a `SingleChildScrollView`
wrapping `AnimatedMasonry(columns: 1)` with a per-column `ScrollController` —
masonry sizes itself to `layout.totalHeight` inside a `Stack`, so it needs an
external scrollable, and it takes the controller for its own edge auto-scroll.

This also buys the column measured heights, glide-on-reflow, the staggered
entrance, and the tile caching that exists because note cards are expensive
([masonry.dart:90](../../../app/lib/widgets/masonry.dart)).

Keep the `_ShowAllTile` outside the masonry, below it in the scroll view — it is
not a card and must not be draggable.

### 3. Masonry accepts foreign cards (~1 d — the real work)

Add two optional parameters, both null for every existing caller so the grid is
untouched:

```dart
/// Called when a card from elsewhere is dropped on this masonry, with the
/// index it was dropped at.
final void Function(String noteId, int index)? onAcceptExternal;

/// Whether this masonry should accept [noteId] from elsewhere.
final bool Function(String noteId)? willAcceptExternal;
```

Wrap the `Stack` in a `DragTarget<String>` that:

- rejects ids already in `_orderIds` (that is masonry's own in-flight drag,
  already handled by `_reorderToPointer`);
- on `onMove`, computes the insertion index from the pointer using the same
  slot-hit-test `_reorderToPointer` uses, and inserts a placeholder into
  `_orderIds` so the column opens a real gap under the pointer;
- on `onLeave`, removes the placeholder;
- on accept, reports `(noteId, index)` and lets the store's rebuild replace the
  placeholder with the real card.

The placeholder is the fiddly part: `build` iterates `_orderIds` and looks each
id up in `notesById`, skipping misses ([masonry.dart:463](../../../app/lib/widgets/masonry.dart)),
so a placeholder id already renders as nothing while still occupying a slot.
That is exactly the gap behaviour wanted, and it needs an estimated height —
reuse `_estimatedHeight`, or better, carry the dragged card's measured height
across in the drag data.

**Watch:** `didUpdateWidget` merges incoming ids while a drag is in progress
([masonry.dart:150](../../../app/lib/widgets/masonry.dart)). A cross-column drop
changes both columns' note lists, so both instances take that path in the same
frame. Confirm the source column drops the card cleanly rather than keeping it
in `_orderIds`.

### 4. Desktop board (~0.5 d)

Horizontal auto-scroll while dragging near the board's left/right edges,
alongside the vertical auto-scroll each column already does. Model it on
masonry's `_updateAutoScroll` — same edge-zone ramp, driven by the board's
outer `ScrollController`.

### 5. Phone board: drop on the strip (~1 d)

Do **not** drag across pages. Instead, long-press lifts the card (masonry's
touch path already does this with a 220ms delay so scrolling wins the arena),
and the `_StageStrip` chips in `board_view.dart` become `DragTarget<String>`s.
Drag up, drop on a chip, done — short travel, nothing turns under the finger,
and it reuses the same note-id protocol the sidebar already accepts
([app_drawer.dart:392](../../../app/lib/widgets/app_drawer.dart)).

**The risk to probe first:** `LongPressDraggable` inside a `PageView` inside the
app's existing scroll and drawer gestures. Build a throwaway page with just
those three before wiring the real board.

Keep "Move to column" in the card menu. It stays the guaranteed path and the
only keyboard/screen-reader one.

### 6. Float exhaustion (~0.5 d, can follow)

Repeated midpoints into one gap eventually exhaust double precision. Guard it:
when `positionBetween` produces a gap below an epsilon, renumber that column.

Server side, that is an optional `stage_id` on `ReorderRequest` — present means
write `stage_position` instead of `position`. The reorder `PendingOp` carries
`data: {'ids': [...]}` today, and an added optional key stays readable by queues
written by older builds.

This is a rare repair path, not the hot path, so it can land after the rest.

## Estimate

**3–3.5 days**, down from the design doc's 2–3 days for drag *plus* the ordering
machinery it assumed — the reduction comes from reusing masonry's reorder whole
and from both drop paths collapsing into one store call.

Order: 1 → 2 → 3 → 4 → 5, with 6 whenever. Steps 1 and 2 are independently
shippable and leave the board working exactly as it does today.

## Risks

1. **Phone gesture arena** (step 5). The one genuinely uncertain piece. Probe it
   in isolation before integrating.
2. **Placeholder height** (step 3). A gap that is the wrong size makes the drop
   target lie about where the card will land. Carrying the measured height in
   the drag payload is the fix if `_estimatedHeight` reads badly.
3. **Render cost.** Masonry computes positions for its full item set every build
   with no viewport culling — a deliberate trade for one personal grid, now
   multiplied by column count. Measure with a wide board before assuming it is
   fine.
4. **Two instances updating mid-drag** (step 3's watch item).

## Out of scope

Column reordering by dragging headers. The `position` field, the API, and
`NotesStore.updateStage(position:)` all exist already; only the affordance is
missing, and it is a separate gesture on a separate target.
