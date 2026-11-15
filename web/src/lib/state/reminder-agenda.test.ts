import { describe, expect, it } from "vitest";
import { makeNote, type ChecklistItem, type Note } from "@/lib/models/note";
import { agendaFor, dayOf, movedToDay, occurrenceKey, occurrencesBetween, remindersByDay, scheduledReminders, snoozeAfter } from "./reminder-agenda";

// Ported from `app/test/reminder_agenda_test.dart`.

const note = (id: string, fields: Partial<Note> = {}): Note => makeNote({ id, title: id, ...fields });
const item = (id: string, text: string, done = false): ChecklistItem => ({ id, text, done, depth: 0 });

describe("scheduledReminders", () => {
  it("lists note and item reminders soonest first, skipping trash and checked rows", () => {
    const notes = [
      note("later", { reminderAt: new Date(2030, 5, 1) }),
      note("list", {
        kind: "checklist",
        items: [item("a", "Milk"), item("b", "Eggs", true)],
        itemReminders: {
          a: { itemId: "a", at: new Date(2030, 0, 1), repeat: null },
          b: { itemId: "b", at: new Date(2029, 0, 1), repeat: null },
        },
      }),
      note("bin", { trashed: true, reminderAt: new Date(2029, 0, 1) }),
    ];
    const scheduled = scheduledReminders(notes);
    expect(scheduled.map(occurrenceKey)).toEqual(["list#a", "later"]);
  });
});

describe("occurrencesBetween", () => {
  it("projects a weekly reminder onto every week of the window", () => {
    const first = new Date(2026, 0, 5, 9, 0);
    const scheduled = scheduledReminders([note("w", { reminderAt: first, reminderRepeat: "weekly" })]);
    const found = occurrencesBetween(scheduled, new Date(2026, 0, 1), new Date(2026, 1, 1));
    expect(found.map((o) => o.at.getDate())).toEqual([5, 12, 19, 26]);
    expect(found.map((o) => o.projected)).toEqual([false, true, true, true]);
  });

  it("clamps a monthly reminder to the end of a short month", () => {
    const scheduled = scheduledReminders([note("m", { reminderAt: new Date(2026, 0, 31, 8), reminderRepeat: "monthly" })]);
    const feb = occurrencesBetween(scheduled, new Date(2026, 1, 1), new Date(2026, 2, 1));
    expect(feb.map((o) => o.at.getDate())).toEqual([28]);
  });

  it("groups by local day", () => {
    const scheduled = scheduledReminders([note("a", { reminderAt: new Date(2026, 2, 3, 9) }), note("b", { reminderAt: new Date(2026, 2, 3, 18) })]);
    const days = remindersByDay(scheduled, new Date(2026, 2, 1), new Date(2026, 3, 1));
    expect(days.get(new Date(2026, 2, 3).getTime())?.map((o) => o.note.id)).toEqual(["a", "b"]);
  });
});

describe("agenda", () => {
  it("puts past reminders in earlier and groups the rest per day", () => {
    const now = new Date(2026, 4, 10, 12);
    const scheduled = scheduledReminders([
      note("past", { reminderAt: new Date(2026, 4, 9, 9) }),
      note("today", { reminderAt: new Date(2026, 4, 10, 8) }),
      note("today2", { reminderAt: new Date(2026, 4, 10, 20) }),
      note("next", { reminderAt: new Date(2026, 4, 12, 9) }),
    ]);
    const agenda = agendaFor(scheduled, now);
    expect(agenda.earlier.map((o) => o.note.id)).toEqual(["past"]);
    expect(agenda.days.map((d) => d.reminders.map((o) => o.note.id))).toEqual([["today", "today2"], ["next"]]);
    expect(agenda.days[0]?.day.getTime()).toBe(dayOf(now).getTime());
  });

  it("snoozes from now and moves to a day keeping the time", () => {
    const now = new Date(2026, 4, 10, 22, 15);
    expect(snoozeAfter("hour", now)).toEqual(new Date(2026, 4, 10, 23, 15));
    expect(snoozeAfter("tomorrow", now)).toEqual(new Date(2026, 4, 11, 9));
    expect(snoozeAfter("nextWeek", now)).toEqual(new Date(2026, 4, 17, 9));
    expect(movedToDay(new Date(2026, 0, 1, 7, 30), new Date(2026, 5, 2))).toEqual(new Date(2026, 5, 2, 7, 30));
  });
});
