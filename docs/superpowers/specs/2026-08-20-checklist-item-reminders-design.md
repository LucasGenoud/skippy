# Reminders per checklist item, Design

**Date:** 2026-08-20
**Status:** implemented.

## Goal

A reminder on an individual checklist item, not only on the note that holds it.
"Remind me about *Call the plumber* on Thursday at 9" without splitting the item
out into a note of its own.

Delivery must reach both transports the note-level reminder already uses: the
server sweep (ntfy/Telegram) and the device's own local alarm scheduler.

## Where the reminder lives

An item reminder is stored in its own table, keyed by `(note_id, item_id)`,
**not** as a field inside the note's `items` JSON.

```sql
CREATE TABLE note_item_reminders (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,
    reminder_at TEXT NOT NULL,
    reminder_repeat TEXT,   -- daily|weekly|monthly|yearly, or NULL
    fired_at TEXT,          -- server-owned, never on the wire
    PRIMARY KEY (note_id, item_id)
);
```

Storing it inside `items` looks cheaper and is not, for four reasons that all
follow from `items` being one opaque, client-written blob:

1. **It would count as a content edit.** `changes_content` compares whole item
   vectors, so setting a reminder would trigger version capture, re-embedding,
   an auto-labeling LLM call, and a collaborator notification. `AGENTS.md`
   requires organization-only edits to keep their smaller side-effect set, and a
   reminder is organization, exactly like the note-level one.
2. **`fired_at` is server-owned.** Inside `items` it becomes client-writable,
   so a client could suppress or replay a delivery.
3. **A stale client would wipe reminders.** Offline writes PATCH the entire
   items array. A client that predates the feature, or simply has an older copy,
   would clear every reminder in the note as a side effect of ticking one box.
4. **The sweep needs an index.** `due_reminders` is one indexed query; JSON
   items would force a `json_each` scan of every note every 30 seconds, and the
   atomic claim that makes delivery at-most-once would become a
   compare-and-swap over a whole blob.

The separate table costs a table, six repository methods that are near-copies of
existing tested ones, and one endpoint. That is the cheaper side of the trade.

## The invariant

> An item reminder exists only for an item that is present in the note and
> unchecked.

It is enforced in three places, deliberately overlapping:

- **`update_note` prunes**, in the same transaction that writes `items`. Any
  reminder whose item vanished or just got checked off goes with it. Putting it
  at the storage seam rather than in the handler means the version-restore path,
  the chat write path, and anything added later cannot forget it.
- **The endpoint rejects** a reminder on an unknown or already-checked item
  (400), so the invariant is never briefly false.
- **The sweep self-heals**: a due row whose item is gone or checked is deleted
  instead of delivered, which covers rows written before a rule changed.

Checking an item therefore cancels its reminder, which is what a to-do list
should do, and the client mirrors that locally so the device alarm is dropped
without waiting for a round trip.

## Wire contract

`NoteView` grows a read-only decoration, assembled in `build_note_views`
alongside labels and attachments:

```json
"item_reminders": [
  {"item_id": "…", "reminder_at": "2026-08-21T09:00:00+02:00", "reminder_repeat": null}
]
```

It is **not** writable through `PATCH /api/notes/{id}`. Writes go to a
sub-resource, one item at a time, so two devices editing two different items of
the same list never clobber each other:

```
PUT /api/notes/{id}/item-reminders/{item_id}
{"reminder_at": "2026-08-21T09:00:00+02:00", "reminder_repeat": "weekly"}
{"reminder_at": null}   -> clears
```

Any participant may write one: reminders are shared note state, like pin,
colour, and the note-level reminder.

`POST /api/notes` accepts `item_reminders` as well. That is what lets an
offline-created checklist, and a restored backup, arrive complete instead of
needing a follow-up write per item.

Setting an item reminder does not bump the note's `updated_at`: it is not an
edit, and the note should not read as "Edited just now" because an alarm moved.
Participants still get a change nudge so their devices re-arm.

## Delivery

`sweep_due_item_reminders` mirrors `sweep_due_reminders` exactly, including the
claim-before-send ordering that keeps a broken channel from wedging the sweep
into resending forever. One-shot reminders are marked fired; recurring ones
advance to their next future occurrence and nudge participants so clients re-arm.

Rendering puts the item first, because the item is the actionable thing:

| | title | body |
|---|---|---|
| note reminder | note title, or "Reminder" | note content / unchecked items |
| item reminder | item text, or "Reminder" | note title (omitted when empty) |

`reminderText` in `util/reminder_schedule.dart` mirrors it, so the same reminder
reads identically whether it arrives from the server or from the device.

## Device alarms

`plannedReminders` now emits one alarm per note reminder **and** one per item
reminder. Two things change in the identity scheme:

- Notification id is `FNV(noteId)` for a note reminder, unchanged, and
  `FNV("noteId#itemId")` for an item reminder. Existing alarms keep their ids,
  so upgrading does not re-arm everything.
- The payload gains an optional item segment:
  `skippy-reminder:<noteId>#<itemId>|<dueMillis>`. Note ids are UUIDs and carry
  no `#`, so the old two-part payload still parses and a tap still resolves to
  the note.

The iOS 64-pending cap is unchanged and now shared between notes and items: the
soonest 64 win. A checklist with dozens of dated items can crowd out a distant
note reminder, which is the correct priority and worth knowing.

## Client model

`Note.itemReminders` is a `Map<String, ItemReminder>` on the note, **not** a
field on `ChecklistItem`. Keeping it off the item is what stops it leaking into
the three places that treat `items` as content:

- content PATCHes (`_contentPatchOp`) stay reminder-free,
- version history snapshots stay content-only,
- the editor's undo stack does not make "set a reminder" an undoable text edit
  it could not actually undo (the reminder is a server sub-resource, so undo
  would desync local state from the server).

Writes are optimistic and queued like every other mutation, through a new
`itemReminder` pending operation, so setting one offline works and survives a
restart.

## UI

In the editor's checklist, each unchecked row gains a bell button beside its
remove button, fading in on hover/focus on desktop and always visible on touch,
exactly like the controls already there. A row with a reminder shows a chip
under its text with the due time (past due reads in the error colour), and the
chip reopens the picker.

The existing `ReminderPicker` is reused, restricted to its time branch. Location
reminders stay note-scoped: they are keyed per note in the settings document and
capped by the platform's geofence budget, so per-item location reminders are a
separate piece of work with a different constraint.

Checked rows show no bell: the invariant says they cannot carry a reminder.

## Cross-cutting

Because a note can now be "a note with a reminder" without `reminder_at` being
set, everything that asks that question was updated to ask it of the note *and*
its items: the drawer's Reminders view (and its sort, now by soonest upcoming
reminder of either kind), the `has:reminder` search operator, workspace stats,
JSON export, and zip backup round-tripping.

## Deferred

- **Per-item location reminders.** See above.
- **A per-item snooze.** The note-level reminder has none either.
- **Reminder chips in the card preview.** The grid card shows a checklist
  preview; showing per-item alarms there would compete with the note's own
  reminder chip for the same corner.
