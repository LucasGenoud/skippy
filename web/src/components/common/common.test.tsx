import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { ColorPicker, PatternPicker } from "./color-picker"
import { FormErrorBanner } from "./form-error-banner"
import { LabelChip } from "./label-chip"
import { MenuLabel } from "./menu-label"
import { ProgressRing } from "./progress-ring"
import { ReminderChip } from "./reminder-chip"
import { reminderPresets } from "./reminder-format"
import { SyncPill } from "./sync-pill"

afterEach(cleanup)

describe("reminderPresets", () => {
  it("matches the Dart presets, next week landing on Monday 9:00", () => {
    // Wednesday 2026-11-11 14:30.
    const now = new Date(2026, 10, 11, 14, 30)
    const byId = Object.fromEntries(reminderPresets(now).map((p) => [p.id, p.at]))
    expect(byId["tomorrow-morning"]).toEqual(new Date(2026, 10, 12, 9))
    expect(byId["tomorrow-evening"]).toEqual(new Date(2026, 10, 12, 18))
    expect(byId["next-week"]).toEqual(new Date(2026, 10, 16, 9))
    expect(byId["in-seven-days"]).toEqual(new Date(2026, 10, 18, 14, 30))
  })

  it("sends a Monday to the Monday after", () => {
    const monday = new Date(2026, 10, 16, 8)
    const nextWeek = reminderPresets(monday).find((p) => p.id === "next-week")
    expect(nextWeek?.at).toEqual(new Date(2026, 10, 23, 9))
  })
})

describe("ReminderChip", () => {
  it("strikes through a reminder in the past and names its repeat", () => {
    render(<ReminderChip at={new Date(2020, 0, 1)} repeat="weekly" label="Jan 1" now={new Date(2026, 0, 1)} />)
    const text = screen.getByText("Jan 1 · Every week")
    expect(text.className).toContain("line-through")
  })

  it("is a button only when it opens something", () => {
    const onClick = vi.fn()
    render(<ReminderChip at={new Date(2030, 0, 1)} label="Soon" onClick={onClick} />)
    fireEvent.click(screen.getByRole("button"))
    expect(onClick).toHaveBeenCalled()
  })
})

describe("small parts", () => {
  it("says how far a checklist is", () => {
    render(<ProgressRing done={2} total={5} />)
    expect(screen.getByRole("img", { name: "2 of 5 tasks done" })).toBeTruthy()
  })

  it("labels the sync state", () => {
    render(<SyncPill state="error" count={3} />)
    expect(screen.getByRole("status", { name: "Sync status: Not synced" })).toBeTruthy()
  })

  it("never shows an empty error banner", () => {
    render(<FormErrorBanner message="  " />)
    expect(screen.getByRole("alert").textContent).toContain("Something went wrong")
  })

  it("puts a menu hint beside its label", () => {
    render(<MenuLabel label="Duplicate" hint="Make a copy" />)
    expect(screen.getByText("Make a copy")).toBeTruthy()
  })

  it("tints a label chip with its colour", () => {
    render(<LabelChip name="Work" color="#1A73E8" icon="work" />)
    expect(screen.getByText("Work").parentElement?.style.color).toBe("rgb(26, 115, 232)")
  })
})

describe("pickers", () => {
  it("picks a note colour", () => {
    const onChange = vi.fn()
    render(<ColorPicker value="default" onChange={onChange} brightness="light" />)
    fireEvent.click(screen.getByRole("radio", { name: "Blue" }))
    expect(onChange).toHaveBeenCalledWith("blue")
    expect(screen.getByRole("radio", { name: "Default" }).getAttribute("aria-checked")).toBe("true")
  })

  it("offers every pattern", () => {
    const onChange = vi.fn()
    render(<PatternPicker value="none" onChange={onChange} />)
    expect(screen.getAllByRole("radio")).toHaveLength(20)
    fireEvent.click(screen.getByRole("radio", { name: "Hearts" }))
    expect(onChange).toHaveBeenCalledWith("hearts")
  })
})
