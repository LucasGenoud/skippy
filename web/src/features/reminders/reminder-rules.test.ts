import { describe, expect, it } from "vitest";

import { makeNote } from "@/lib/models/note";
import { scheduledReminders } from "@/lib/state/reminder-agenda";

import { clearedLabel, dayHeading, daysBetween, monthGridRange, reminderCountLabel, remindersSummary, weekStartsOn } from "./reminder-rules";

const fmt = (d: Date, withYear: boolean): string => `${d.getDate()}/${d.getMonth() + 1}${withYear ? `/${d.getFullYear()}` : ""}`;

describe("remindersSummary", () => {
  const now = new Date(2026, 10, 12, 10, 0); // Thu 12 Nov 2026, 10:00

  it("counts later today and upcoming", () => {
    const scheduled = scheduledReminders([
      makeNote({ id: "past", reminderAt: new Date(2026, 10, 12, 8, 0) }),
      makeNote({ id: "later", reminderAt: new Date(2026, 10, 12, 18, 0) }),
      makeNote({ id: "tomorrow", reminderAt: new Date(2026, 10, 13, 9, 0) }),
    ]);
    expect(remindersSummary(scheduled, now)).toBe("1 later today · 2 upcoming");
  });

  it("says when nothing is coming", () => {
    expect(remindersSummary([], now)).toBe("Nothing coming up");
  });
});

describe("dayHeading", () => {
  const now = new Date(2026, 10, 12, 10, 0); // Thursday

  it("names nearby days relatively", () => {
    expect(dayHeading(new Date(2026, 10, 12), now, fmt)).toEqual({ title: "Today", subtitle: "Thursday, 12/11", isToday: true });
    expect(dayHeading(new Date(2026, 10, 11), now, fmt).title).toBe("Yesterday");
    expect(dayHeading(new Date(2026, 10, 13), now, fmt)).toEqual({ title: "Tomorrow", subtitle: "Friday, 13/11", isToday: false });
  });

  it("uses the weekday within the week, with the date under it", () => {
    expect(dayHeading(new Date(2026, 10, 16), now, fmt)).toEqual({ title: "Monday", subtitle: "16/11", isToday: false });
  });

  it("uses the date further out, with the year only in another year", () => {
    expect(dayHeading(new Date(2026, 10, 30), now, fmt)).toEqual({ title: "30/11", subtitle: "Monday", isToday: false });
    expect(dayHeading(new Date(2027, 0, 4), now, fmt).title).toBe("4/1/2027");
  });
});

describe("calendar arithmetic", () => {
  it("counts calendar days across a daylight-saving change", () => {
    expect(daysBetween(new Date(2026, 2, 28, 23, 0), new Date(2026, 2, 30, 1, 0))).toBe(2);
  });

  it("starts the week on Sunday where the month is written first", () => {
    expect(weekStartsOn("monthFirst")).toBe(0);
    expect(weekStartsOn("numericUS")).toBe(0);
    expect(weekStartsOn("dayFirst")).toBe(1);
    expect(weekStartsOn("iso")).toBe(1);
  });

  it("draws six weeks from the week holding the 1st", () => {
    // November 2026 starts on a Sunday.
    const monday = monthGridRange(new Date(2026, 10, 20), 1);
    expect(monday.start).toEqual(new Date(2026, 9, 26));
    expect(monday.end).toEqual(new Date(2026, 11, 7));
    const sunday = monthGridRange(new Date(2026, 10, 1), 0);
    expect(sunday.start).toEqual(new Date(2026, 10, 1));
  });

  it("words counts", () => {
    expect(reminderCountLabel(0)).toBe("no reminders");
    expect(reminderCountLabel(1)).toBe("1 reminder");
    expect(reminderCountLabel(4)).toBe("4 reminders");
    expect(clearedLabel(1)).toBe("Cleared 1 past reminder");
    expect(clearedLabel(2)).toBe("Cleared 2 past reminders");
  });
});
