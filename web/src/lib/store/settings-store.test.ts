import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NOTIFY_CHANNELS, channelConfiguredIn } from "@/lib/models/notify-channels";
import { FakeApi } from "@/tests/fake-api";
import { configuredNotifyChannels, DEFAULT_ACCENT, DEFAULT_PALETTE, editedLabel, formatClock, formatDate, isManaged, notifyConfigured, reminderLabel, resolveNoteColor, SettingsStore } from "./settings-store";

// Ported from `app/test/settings_store_test.dart`.

let api: FakeApi;
let settings: SettingsStore;
const settleSave = async (): Promise<void> => {
  await vi.advanceTimersByTimeAsync(700);
};

beforeEach(() => {
  vi.useFakeTimers();
  api = new FakeApi();
  settings = new SettingsStore(api);
});

afterEach(() => {
  settings.dispose();
  vi.useRealTimers();
});

it("has sane defaults before and after loading empty settings", async () => {
  expect(settings.state.themeMode).toBe("system");
  await settings.load();
  expect(settings.state.loaded).toBe(true);
  expect(settings.state.accentColor).toBe(DEFAULT_ACCENT);
  expect(settings.state.palette).toEqual(DEFAULT_PALETTE);
  expect(settings.state.semanticSearchCapable).toBe(true);
  expect(settings.state.semanticSearchEnabled).toBe(true);
});

it("persists mutations to the server and round-trips them", async () => {
  await settings.load();
  settings.setThemeMode("dark");
  settings.setAccentColor("#123abc");
  settings.setGridDensity("compact");
  settings.setUse24hTime(false);
  settings.setBoardExitColumn("c1", "archive", true);
  settings.addPaletteColor("Mint", "#aaffcc", "#113322");
  await settleSave();
  expect(api.settings).toMatchObject({ theme: "dark", accent: "#123ABC", grid_density: "compact", time_format: "12h", board_exit_columns: { c1: ["archive"] } });

  const reloaded = new SettingsStore(api);
  await reloaded.load();
  expect(reloaded.state).toMatchObject({ themeMode: "dark", accentColor: "#123ABC", gridDensity: "compact", use24hTime: false });
  expect(reloaded.state.palette.at(-1)).toMatchObject({ name: "Mint", light: "#AAFFCC", dark: "#113322" });
  reloaded.dispose();
});

it("keeps retrying a failed save and lets remote changes in once it lands", async () => {
  await settings.load();
  api.failWith = new TypeError("Failed to fetch");
  settings.setThemeMode("dark");
  await settleSave();
  expect(settings.hasPendingSave).toBe(true);
  api.failWith = null;
  await vi.advanceTimersByTimeAsync(5_000);
  expect(settings.hasPendingSave).toBe(false);
  expect(api.settings.theme).toBe("dark");
  api.settings = { ...api.settings, theme: "light" };
  await settings.load();
  expect(settings.state.themeMode).toBe("light");
});

it("cycles the theme through the system default", () => {
  settings.cycleThemeMode();
  expect(settings.state.themeMode).toBe("light");
  settings.cycleThemeMode();
  expect(settings.state.themeMode).toBe("dark");
  settings.cycleThemeMode();
  expect(settings.state.themeMode).toBe("system");
});

it("falls back to defaults per malformed field and keeps unknown native data", async () => {
  api.settings = { theme: 42, accent: "nope", grid_width: "huge", palette: [{ key: "x" }], saved_locations: [{ id: "home" }] };
  await settings.load();
  expect(settings.state).toMatchObject({ themeMode: "system", accentColor: DEFAULT_ACCENT, gridWidth: "medium" });
  expect(settings.state.palette).toEqual(DEFAULT_PALETTE);
  settings.setThemeMode("dark");
  await settleSave();
  expect(api.settings.saved_locations).toEqual([{ id: "home" }]);
});

it("overrides, locks and hides managed keys", async () => {
  api.settings = { llm_base_url: "http://user/v1", llm_api_key: "sk-user", llm_model: "user-model" };
  api.managedSettings = {
    llm_base_url: { secret: false, value: "http://managed/v1" },
    llm_api_key: { secret: true, value: null },
    llm_model: { secret: false, value: "managed-model" },
    llm_chat: { secret: false, value: false },
  };
  await settings.load();
  expect(settings.state.llmBaseUrl).toBe("http://managed/v1");
  expect(settings.state.llmModel).toBe("managed-model");
  expect(settings.state.llmApiKey).toBe("");
  expect(isManaged(settings.state, "llm_chat")).toBe(true);
  expect(isManaged(settings.state, "llm_labeling")).toBe(false);
});

it("never overwrites the user's own value for a managed key", async () => {
  api.settings = { llm_base_url: "http://user/v1", llm_api_key: "sk-user", llm_model: "user-model", smtp_host: "mail.mine", smtp_password: "pw" };
  api.managedSettings = {
    llm_base_url: { secret: false, value: "http://managed/v1" },
    llm_api_key: { secret: true, value: null },
    smtp_host: { secret: false, value: "mail.host" },
    smtp_password: { secret: true, value: null },
  };
  await settings.load();
  settings.setThemeMode("dark");
  await settleSave();
  expect(api.settings).toMatchObject({ llm_base_url: "http://user/v1", llm_api_key: "sk-user", llm_model: "user-model", smtp_host: "mail.mine", smtp_password: "pw", theme: "dark" });
});

it("counts a channel the server completes as configured", async () => {
  api.settings = { smtp_to: "ada@example.test" };
  api.managedSettings = {
    smtp_host: { secret: false, value: "mail.host" },
    smtp_from: { secret: false, value: "bot@host" },
    smtp_password: { secret: true, value: null },
  };
  await settings.load();
  expect(settings.state.notifyValues.smtp_host).toBe("mail.host");
  expect(settings.state.notifyValues.smtp_password).toBe("");
  expect(notifyConfigured(settings.state)).toBe(true);
  expect(configuredNotifyChannels(settings.state)).toEqual(["Email"]);
});

it("treats the username as the sender's stand-in", () => {
  const email = NOTIFY_CHANNELS.find((c) => c.key === "email");
  expect(email && channelConfiguredIn(email, { smtp_host: "h", smtp_to: "a@b.test" })).toBe(false);
  expect(email && channelConfiguredIn(email, { smtp_host: "h", smtp_to: "a@b.test", smtp_username: "bot@b.test" })).toBe(true);
});

describe("formatting", () => {
  it("follows the date and time preferences", () => {
    const t = new Date(2026, 6, 15, 18, 5);
    expect(formatClock(t, true)).toBe("18:05");
    expect(formatClock(t, false)).toBe("6:05 PM");
    expect(formatDate(t, "monthFirst")).toBe("Jul 15, 2026");
    expect(formatDate(t, "dayFirst", false)).toBe("15 Jul");
    expect(formatDate(t, "numericUS")).toBe("07/15/2026");
    expect(formatDate(t, "numericEU")).toBe("15.07.2026");
    expect(formatDate(t, "iso")).toBe("2026-07-15");
    const now = new Date(2026, 6, 15, 9);
    expect(reminderLabel(t, { use24hTime: true, dateFormat: "dayFirst" }, now)).toBe("Today 18:05");
    expect(reminderLabel(new Date(2026, 6, 16, 9), { use24hTime: true, dateFormat: "dayFirst" }, now)).toBe("Tomorrow 09:00");
    expect(editedLabel(new Date(now.getTime() - 30_000), { use24hTime: true, dateFormat: "dayFirst" }, now)).toBe("just now");
    expect(editedLabel(new Date(now.getTime() - 5 * 60_000), { use24hTime: true, dateFormat: "dayFirst" }, now)).toBe("5m ago");
  });

  it("resolves note colours from the palette, then the defaults", async () => {
    await settings.load();
    expect(resolveNoteColor(settings.state, "default", "light")).toBeNull();
    expect(resolveNoteColor(settings.state, "red", "dark")).toBe("#5C2B29");
    settings.removePaletteColor("red");
    expect(resolveNoteColor(settings.state, "red", "light")).toBe("#F28B82");
    expect(resolveNoteColor(settings.state, "nope", "light")).toBeNull();
  });
});
