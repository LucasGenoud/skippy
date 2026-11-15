import { createStore, type StoreApi } from "zustand/vanilla";
import type { Api } from "@/lib/api/client";
import {
  channelConfiguredIn,
  DEFAULT_REWRITE_TASKS,
  NOTIFY_CHANNELS,
  NOTIFY_FIELD_KEYS,
  parseRewriteTask,
  type ManagedSetting,
  type NoteRewriteTask,
  type UrlSummaryLength,
} from "@/lib/models";
import { hexToRgb, rgbToHex } from "@/lib/theme/color";
import { asArray, asObject, type JsonObject } from "@/lib/util/json";

// Per-user preferences, synced to the server as an opaque JSON document so
// they follow the user across devices. Ported from `state/settings_store.dart`:
// defaults, load, `toJson`, every mutation, the managed overlay with
// `_ownManagedValues`, and the retrying debounced save.

export type ThemeMode = "system" | "light" | "dark";

export const APP_FONTS = [
  { id: "system", label: "System default", family: null },
  { id: "inter", label: "Inter", family: "Inter" },
  { id: "nunito", label: "Nunito", family: "Nunito" },
  { id: "lora", label: "Lora", family: "Lora" },
  { id: "jetBrainsMono", label: "JetBrains Mono", family: "JetBrainsMono" },
] as const;
export type AppFont = (typeof APP_FONTS)[number]["id"];

export const DATE_FORMATS = [
  { id: "monthFirst", label: "Month day year", example: "Jul 15, 2026" },
  { id: "dayFirst", label: "Day month year", example: "15 Jul 2026" },
  { id: "numericUS", label: "Month/day/year", example: "07/15/2026" },
  { id: "numericEU", label: "Day.month.year", example: "15.07.2026" },
  { id: "iso", label: "Year-month-day", example: "2026-07-15" },
] as const;
export type AppDateFormat = (typeof DATE_FORMATS)[number]["id"];

/** How tightly the grid packs cards: the ideal card width and a column cap. */
export const GRID_DENSITIES = [
  { id: "compact", label: "Compact", blurb: "More, smaller cards", targetWidth: 200, maxColumns: 8 },
  { id: "comfortable", label: "Comfortable", blurb: "The default balance", targetWidth: 250, maxColumns: 6 },
  { id: "spacious", label: "Spacious", blurb: "Fewer, larger cards", targetWidth: 320, maxColumns: 5 },
] as const;
export type GridDensity = (typeof GRID_DENSITIES)[number]["id"];

/** How wide the centred grid may grow. */
export const GRID_WIDTHS = [
  { id: "narrow", label: "Narrow", maxWidth: 1100 },
  { id: "medium", label: "Medium", maxWidth: 1400 },
  { id: "wide", label: "Wide", maxWidth: 1800 },
  { id: "full", label: "Full", maxWidth: Number.POSITIVE_INFINITY },
] as const;
export type GridWidth = (typeof GRID_WIDTHS)[number]["id"];

/** Board exit columns a user may show per collection. */
export type BoardExit = "archive" | "trash";

/** One entry in the user's note-colour palette; colours are `#RRGGBB`. */
export interface PaletteEntry {
  readonly key: string;
  readonly name: string;
  readonly light: string;
  readonly dark: string;
}

export const DEFAULT_PALETTE: readonly PaletteEntry[] = [
  { key: "red", name: "Red", light: "#F28B82", dark: "#5C2B29" },
  { key: "orange", name: "Orange", light: "#FBBC04", dark: "#614A19" },
  { key: "yellow", name: "Yellow", light: "#FFF475", dark: "#635D19" },
  { key: "green", name: "Green", light: "#CCFF90", dark: "#345920" },
  { key: "teal", name: "Teal", light: "#A7FFEB", dark: "#16504B" },
  { key: "blue", name: "Blue", light: "#AECBFA", dark: "#2D555E" },
  { key: "gray", name: "Gray", light: "#E8EAED", dark: "#3C3F43" },
];

/** The default accent (`kDefaultAccent` in theme.dart). */
export const DEFAULT_ACCENT = "#FBBC04";

/** The backend caps the settings document at 16 KB. */
export const SETTINGS_DOCUMENT_MAX_BYTES = 16 * 1024;

/** `#RRGGBB` in upper case, or null when absent or malformed. */
function normalizeHex(hex: string | null | undefined): string | null {
  const rgb = hexToRgb(hex);
  return rgb ? rgbToHex(rgb).toUpperCase() : null;
}

function parsePaletteEntry(json: unknown): PaletteEntry | null {
  const map = asObject(json);
  if (!map) {
    return null;
  }
  const key = typeof map.key === "string" ? map.key : "";
  const light = normalizeHex(typeof map.light === "string" ? map.light : null);
  const dark = normalizeHex(typeof map.dark === "string" ? map.dark : null);
  if (!key || !light || !dark) {
    return null;
  }
  const name = typeof map.name === "string" && map.name.trim() ? map.name.trim() : key;
  return { key, name, light, dark };
}

export interface SettingsState {
  readonly loaded: boolean;
  readonly themeMode: ThemeMode;
  readonly accentColor: string;
  readonly font: AppFont;
  readonly dateFormat: AppDateFormat;
  readonly use24hTime: boolean;
  readonly defaultListMode: boolean;
  readonly gridDensity: GridDensity;
  readonly gridWidth: GridWidth;
  /** Personal board exits, by collection id. */
  readonly boardExitColumns: Readonly<Record<string, readonly BoardExit[]>>;
  readonly palette: readonly PaletteEntry[];

  // Server capabilities (from /api/capabilities, not persisted).
  readonly semanticSearchCapable: boolean;
  readonly audioTranscriptionCapable: boolean;
  readonly imageOcrCapable: boolean;
  readonly passwordResetCapable: boolean;
  readonly serverVersion: string | null;

  readonly semanticSearchEnabled: boolean;
  /** The live "rank by meaning" toggle in search. */
  readonly semanticRanking: boolean;

  // LLM provider (used by the server for workspaces this user owns).
  readonly llmBaseUrl: string;
  readonly llmApiKey: string;
  readonly llmModel: string;
  readonly llmPrompt: string;
  readonly autoSummarizeLinks: boolean;
  readonly linkSummaryLength: UrlSummaryLength;
  readonly llmRewriteTasks: readonly NoteRewriteTask[];
  readonly llmChatCreateEnabled: boolean;
  readonly llmChatEditEnabled: boolean;
  readonly llmChatOrganizeEnabled: boolean;

  /** Keys the server pinned via env vars; a present key is locked in the UI. */
  readonly managed: Readonly<Record<string, ManagedSetting>>;

  /** Notification connector values, keyed by `NOTIFY_FIELD_KEYS`. */
  readonly notifyValues: Readonly<Record<string, string>>;
  readonly reminderNotificationsEnabled: boolean;
  readonly deviceNotificationsEnabled: boolean;

  /** Native-only personal places, carried through untouched on the web. */
  readonly savedLocations: readonly JsonObject[];
  readonly locationReminders: readonly JsonObject[];
}

export const DEFAULT_SETTINGS: SettingsState = {
  loaded: false,
  themeMode: "system",
  accentColor: DEFAULT_ACCENT,
  font: "system",
  dateFormat: "dayFirst",
  use24hTime: true,
  defaultListMode: false,
  gridDensity: "comfortable",
  gridWidth: "medium",
  boardExitColumns: {},
  palette: DEFAULT_PALETTE,
  semanticSearchCapable: false,
  audioTranscriptionCapable: false,
  imageOcrCapable: false,
  passwordResetCapable: false,
  serverVersion: null,
  semanticSearchEnabled: true,
  semanticRanking: false,
  llmBaseUrl: "",
  llmApiKey: "",
  llmModel: "",
  llmPrompt: "",
  autoSummarizeLinks: false,
  linkSummaryLength: "short",
  llmRewriteTasks: DEFAULT_REWRITE_TASKS,
  llmChatCreateEnabled: true,
  llmChatEditEnabled: true,
  llmChatOrganizeEnabled: true,
  managed: {},
  notifyValues: {},
  reminderNotificationsEnabled: true,
  deviceNotificationsEnabled: false,
  savedLocations: [],
  locationReminders: [],
};

// Derived facts, as functions of the state so selectors can use them.

export const semanticSearchAvailable = (s: SettingsState): boolean => s.semanticSearchCapable && s.semanticSearchEnabled;
export const llmConfigured = (s: SettingsState): boolean => s.llmBaseUrl !== "" && s.llmModel !== "";
export const isManaged = (s: SettingsState, key: string): boolean => key in s.managed;
export const notifyConfigured = (s: SettingsState): boolean => NOTIFY_CHANNELS.some((c) => channelConfiguredIn(c, s.notifyValues));
export const configuredNotifyChannels = (s: SettingsState): string[] =>
  NOTIFY_CHANNELS.filter((c) => channelConfiguredIn(c, s.notifyValues)).map((c) => c.label);
export const boardExitsFor = (s: SettingsState, collectionId: string | null | undefined): readonly BoardExit[] =>
  collectionId ? (s.boardExitColumns[collectionId] ?? []) : [];

/** Resolved fill for a note colour key in [scheme]; null means the plain surface. */
export function resolveNoteColor(s: SettingsState, key: string, scheme: "light" | "dark"): string | null {
  if (key === "default") {
    return null;
  }
  const entry = s.palette.find((e) => e.key === key) ?? DEFAULT_PALETTE.find((e) => e.key === key);
  return entry ? entry[scheme] : null;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad2 = (v: number): string => String(v).padStart(2, "0");

/** "18:30" or "6:30 PM". */
export function formatClock(t: Date, use24hTime: boolean): string {
  const m = pad2(t.getMinutes());
  if (use24hTime) {
    return `${pad2(t.getHours())}:${m}`;
  }
  const h = t.getHours() % 12 === 0 ? 12 : t.getHours() % 12;
  return `${h}:${m} ${t.getHours() < 12 ? "AM" : "PM"}`;
}

export function formatDate(d: Date, format: AppDateFormat, withYear = true): string {
  const dd = pad2(d.getDate());
  const mm = pad2(d.getMonth() + 1);
  const month = MONTHS[d.getMonth()] ?? "";
  switch (format) {
    case "monthFirst":
      return `${month} ${d.getDate()}${withYear ? `, ${d.getFullYear()}` : ""}`;
    case "dayFirst":
      return `${d.getDate()} ${month}${withYear ? ` ${d.getFullYear()}` : ""}`;
    case "numericUS":
      return `${mm}/${dd}/${d.getFullYear()}`;
    case "numericEU":
      return `${dd}.${mm}.${d.getFullYear()}`;
    case "iso":
      return `${d.getFullYear()}-${mm}-${dd}`;
  }
}

const MS_PER_DAY = 86_400_000;

/** "Today 9:00 AM", "Tomorrow 18:30", "Jul 24, 2026, 9:00 AM". */
export function reminderLabel(t: Date, s: Pick<SettingsState, "use24hTime" | "dateFormat">, now: Date = new Date()): string {
  const day = new Date(t.getFullYear(), t.getMonth(), t.getDate()).getTime();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const delta = Math.round((day - today) / MS_PER_DAY);
  const clock = formatClock(t, s.use24hTime);
  if (delta === 0) {
    return `Today ${clock}`;
  }
  if (delta === 1) {
    return `Tomorrow ${clock}`;
  }
  if (delta === -1) {
    return `Yesterday ${clock}`;
  }
  return `${formatDate(t, s.dateFormat, t.getFullYear() !== now.getFullYear())}, ${clock}`;
}

/** Relative stamp for "Edited …". */
export function editedLabel(t: Date, s: Pick<SettingsState, "use24hTime" | "dateFormat">, now: Date = new Date()): string {
  const diffMs = now.getTime() - t.getTime();
  const minutes = Math.floor(diffMs / 60_000);
  if (diffMs < 60_000) {
    return "just now";
  }
  if (minutes < 60) {
    return `${minutes}m ago`;
  }
  if (diffMs < MS_PER_DAY && now.getDate() === t.getDate()) {
    return formatClock(t, s.use24hTime);
  }
  return formatDate(t, s.dateFormat, t.getFullYear() !== now.getFullYear());
}

const SAVE_DEBOUNCE_MS = 600;
const SAVE_RETRY_BASE_MS = 5_000;
const SAVE_RETRY_MAX_MS = 60_000;
const MAX_RETRY_SHIFT = 4;

function oneOf<T extends string>(value: unknown, options: readonly { id: T }[], fallback: T): T {
  return options.find((o) => o.id === value)?.id ?? fallback;
}

export class SettingsStore {
  readonly store: StoreApi<SettingsState>;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  private savePending = false;
  private saveAttempt = 0;
  private disposed = false;
  private customCounter = 0;
  /** What the user's own document held for each manageable key, before the overlay. */
  private ownManagedValues: Record<string, string> = {};

  constructor(private readonly api: Api) {
    this.store = createStore<SettingsState>(() => DEFAULT_SETTINGS);
  }

  get state(): SettingsState {
    return this.store.getState();
  }

  /** Everything observable, serialized, to skip notifying a no-op refetch. */
  private fingerprint(s: SettingsState): string {
    return JSON.stringify({
      doc: this.toJson(s),
      caps: [s.semanticSearchCapable, s.audioTranscriptionCapable, s.imageOcrCapable, s.passwordResetCapable, s.serverVersion],
      managed: s.managed,
      overlay: [s.llmBaseUrl, s.llmApiKey, s.llmModel, s.notifyValues],
    });
  }

  /** Re-pull capabilities, managed keys and (unless a save is pending) the document. */
  async load(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const wasLoaded = this.state.loaded;
    const before = this.fingerprint(this.state);
    // Each read is independent; an unreachable server leaves its part as it was.
    const caps = await this.api.fetchCapabilities().catch(() => null);
    const managed = await this.api.fetchManagedSettings().catch(() => null);
    // Never clobber local edits that have not reached the server.
    const doc = this.savePending ? null : await this.api.fetchSettings().catch(() => null);
    if (this.disposed) {
      return;
    }
    let next: SettingsState = { ...this.state };
    if (caps) {
      next = {
        ...next,
        semanticSearchCapable: caps.semanticSearch,
        audioTranscriptionCapable: caps.audioTranscription,
        imageOcrCapable: caps.imageOcr,
        passwordResetCapable: caps.passwordReset,
        serverVersion: caps.serverVersion,
      };
    }
    if (managed) {
      next = { ...next, managed };
    }
    if (doc && !this.savePending) {
      next = this.applyJson(next, doc);
    }
    // Managed values win over whatever the user's document carried.
    next = { ...this.applyManaged(next), loaded: true };
    if (!wasLoaded || this.fingerprint(next) !== before) {
      this.store.setState(next, true);
    }
  }

  /** Overlay managed values so the UI shows what the server will use. Secrets blank. */
  private applyManaged(s: SettingsState): SettingsState {
    const text = (key: string): string | null => {
      const m = s.managed[key];
      if (!m) {
        return null;
      }
      return m.secret ? "" : typeof m.value === "string" ? m.value : "";
    };
    const notifyValues = { ...s.notifyValues };
    for (const key of NOTIFY_FIELD_KEYS) {
      const value = text(key);
      if (value !== null) {
        notifyValues[key] = value;
      }
    }
    return {
      ...s,
      llmBaseUrl: text("llm_base_url") ?? s.llmBaseUrl,
      llmApiKey: text("llm_api_key") ?? s.llmApiKey,
      llmModel: text("llm_model") ?? s.llmModel,
      notifyValues,
    };
  }

  private applyJson(s: SettingsState, json: JsonObject): SettingsState {
    const theme: ThemeMode = json.theme === "light" || json.theme === "dark" ? json.theme : "system";
    const rawExits = asObject(json.board_exit_columns) ?? {};
    const boardExitColumns: Record<string, BoardExit[]> = {};
    for (const [key, value] of Object.entries(rawExits)) {
      if (Array.isArray(value)) {
        boardExitColumns[key] = value.filter((v): v is BoardExit => v === "archive" || v === "trash");
      }
    }
    const trimmed = (key: string): string => (typeof json[key] === "string" ? (json[key] as string).trim() : "");
    const rawTasks = json.llm_rewrite_tasks;
    const llmRewriteTasks = Array.isArray(rawTasks)
      ? rawTasks.map(parseRewriteTask).filter((t): t is NoteRewriteTask => t !== null)
      : DEFAULT_REWRITE_TASKS;
    const notifyValues: Record<string, string> = {};
    for (const key of NOTIFY_FIELD_KEYS) {
      notifyValues[key] = trimmed(key);
    }
    const llmBaseUrl = trimmed("llm_base_url");
    const llmApiKey = trimmed("llm_api_key");
    const llmModel = trimmed("llm_model");
    // Snapshotted here, not in applyManaged, which also runs when this is skipped.
    this.ownManagedValues = { llm_base_url: llmBaseUrl, llm_api_key: llmApiKey, llm_model: llmModel, ...notifyValues };
    const parsedPalette = asArray(json.palette)
      .map(parsePaletteEntry)
      .filter((e): e is PaletteEntry => e !== null);
    const summary = json.link_summary_length;
    return {
      ...s,
      themeMode: theme,
      accentColor: normalizeHex(typeof json.accent === "string" ? json.accent : null) ?? DEFAULT_ACCENT,
      font: oneOf(json.font, APP_FONTS, "system"),
      dateFormat: oneOf(json.date_format, DATE_FORMATS, "dayFirst"),
      use24hTime: json.time_format !== "12h",
      defaultListMode: json.default_view === "list",
      gridDensity: oneOf(json.grid_density, GRID_DENSITIES, "comfortable"),
      gridWidth: oneOf(json.grid_width, GRID_WIDTHS, "medium"),
      boardExitColumns,
      // Feature toggles default on when absent.
      semanticSearchEnabled: json.semantic_search !== false,
      semanticRanking: json.semantic_ranking === true,
      llmBaseUrl,
      llmApiKey,
      llmModel,
      llmPrompt: trimmed("llm_prompt"),
      autoSummarizeLinks: json.auto_summarize_links === true,
      linkSummaryLength: summary === "medium" || summary === "long" ? summary : "short",
      llmRewriteTasks,
      llmChatCreateEnabled: json.llm_chat_create !== false,
      llmChatEditEnabled: json.llm_chat_edit !== false,
      llmChatOrganizeEnabled: json.llm_chat_organize !== false,
      notifyValues,
      reminderNotificationsEnabled: json.reminder_notifications !== false,
      deviceNotificationsEnabled: json.device_notifications === true,
      savedLocations: asArray(json.saved_locations).filter((e): e is JsonObject => asObject(e) !== null),
      locationReminders: asArray(json.location_reminders).filter((e): e is JsonObject => asObject(e) !== null),
      palette: parsedPalette.length > 0 ? parsedPalette : s.palette,
    };
  }

  /** The settings document as it will be saved. Managed keys carry the user's own values. */
  toJson(s: SettingsState = this.state): JsonObject {
    const doc: JsonObject = {
      theme: s.themeMode,
      accent: s.accentColor.toUpperCase(),
      font: s.font,
      date_format: s.dateFormat,
      time_format: s.use24hTime ? "24h" : "12h",
      default_view: s.defaultListMode ? "list" : "grid",
      grid_density: s.gridDensity,
      grid_width: s.gridWidth,
      board_exit_columns: Object.fromEntries(Object.entries(s.boardExitColumns).map(([k, v]) => [k, [...v]])),
      semantic_search: s.semanticSearchEnabled,
      semantic_ranking: s.semanticRanking,
      llm_base_url: s.llmBaseUrl,
      llm_api_key: s.llmApiKey,
      llm_model: s.llmModel,
      llm_prompt: s.llmPrompt,
      auto_summarize_links: s.autoSummarizeLinks,
      link_summary_length: s.linkSummaryLength,
      llm_rewrite_tasks: s.llmRewriteTasks.map((t) => ({ id: t.id, name: t.name, prompt: t.prompt })),
      llm_chat_create: s.llmChatCreateEnabled,
      llm_chat_edit: s.llmChatEditEnabled,
      llm_chat_organize: s.llmChatOrganizeEnabled,
    };
    // Every notify key appears, or a save from here would erase it.
    for (const key of NOTIFY_FIELD_KEYS) {
      doc[key] = s.notifyValues[key] ?? "";
    }
    Object.assign(doc, {
      reminder_notifications: s.reminderNotificationsEnabled,
      device_notifications: s.deviceNotificationsEnabled,
      saved_locations: [...s.savedLocations],
      location_reminders: [...s.locationReminders],
      palette: s.palette.map((e) => ({ key: e.key, name: e.name, light: e.light.toUpperCase(), dark: e.dark.toUpperCase() })),
    });
    // Managed keys belong to the server; persist what the user configured.
    for (const key of Object.keys(s.managed)) {
      if (key in this.ownManagedValues) {
        doc[key] = this.ownManagedValues[key] ?? "";
      }
    }
    return doc;
  }

  /** Size of the document as it would be saved, against SETTINGS_DOCUMENT_MAX_BYTES. */
  documentBytes(): number {
    return new TextEncoder().encode(JSON.stringify(this.toJson())).length;
  }

  private mutate(change: (s: SettingsState) => Partial<SettingsState>): void {
    if (this.disposed) {
      return;
    }
    this.store.setState(change(this.state));
    this.savePending = true;
    this.saveAttempt = 0;
    this.scheduleSave(SAVE_DEBOUNCE_MS);
  }

  /** Write the document, and keep trying until it lands. */
  private scheduleSave(delayMs: number): void {
    if (this.saveTimer !== null) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(async () => {
      this.saveTimer = null;
      if (this.disposed) {
        return;
      }
      try {
        await this.api.putSettings(this.toJson());
        if (this.disposed) {
          return;
        }
        this.savePending = false;
        this.saveAttempt = 0;
      } catch {
        if (this.disposed) {
          return;
        }
        this.saveAttempt++;
        this.scheduleSave(Math.min(SAVE_RETRY_BASE_MS * 2 ** Math.min(Math.max(this.saveAttempt - 1, 0), MAX_RETRY_SHIFT), SAVE_RETRY_MAX_MS));
      }
    }, delayMs);
  }

  /** Whether a local edit has not reached the server yet. */
  get hasPendingSave(): boolean {
    return this.savePending;
  }

  setThemeMode(mode: ThemeMode): void {
    this.mutate(() => ({ themeMode: mode }));
  }

  /** system -> light -> dark -> system. */
  cycleThemeMode(): void {
    this.mutate((s) => ({ themeMode: s.themeMode === "system" ? "light" : s.themeMode === "light" ? "dark" : "system" }));
  }

  setAccentColor(hex: string): void {
    const color = normalizeHex(hex);
    if (color) {
      this.mutate(() => ({ accentColor: color }));
    }
  }

  setFont(font: AppFont): void {
    this.mutate(() => ({ font }));
  }

  setDateFormat(dateFormat: AppDateFormat): void {
    this.mutate(() => ({ dateFormat }));
  }

  setUse24hTime(use24hTime: boolean): void {
    this.mutate(() => ({ use24hTime }));
  }

  setDefaultListMode(defaultListMode: boolean): void {
    this.mutate(() => ({ defaultListMode }));
  }

  setGridDensity(gridDensity: GridDensity): void {
    this.mutate(() => ({ gridDensity }));
  }

  setGridWidth(gridWidth: GridWidth): void {
    this.mutate(() => ({ gridWidth }));
  }

  /** Show or hide an exit column on [collectionId]'s board, for this user. */
  setBoardExitColumn(collectionId: string | null, exit: BoardExit, visible: boolean): void {
    if (collectionId === null) {
      return;
    }
    this.mutate((s) => {
      const next = new Set(s.boardExitColumns[collectionId] ?? []);
      if (visible) {
        next.add(exit);
      } else {
        next.delete(exit);
      }
      const columns: Record<string, readonly BoardExit[]> = { ...s.boardExitColumns };
      if (next.size === 0) {
        delete columns[collectionId];
      } else {
        columns[collectionId] = [...next];
      }
      return { boardExitColumns: columns };
    });
  }

  setSemanticSearchEnabled(value: boolean): void {
    this.mutate(() => ({ semanticSearchEnabled: value }));
  }

  setSemanticRanking(value: boolean): void {
    this.mutate(() => ({ semanticRanking: value }));
  }

  setLlmConfig(config: { baseUrl: string; apiKey: string; model: string }): void {
    this.mutate(() => ({ llmBaseUrl: config.baseUrl.trim(), llmApiKey: config.apiKey.trim(), llmModel: config.model.trim() }));
  }

  setLinkSummarySettings(options: { automatically: boolean; length: UrlSummaryLength }): void {
    this.mutate(() => ({ autoSummarizeLinks: options.automatically, linkSummaryLength: options.length }));
  }

  setLlmRewriteTasks(tasks: readonly NoteRewriteTask[]): void {
    this.mutate(() => ({ llmRewriteTasks: [...tasks] }));
  }

  setLlmBehavior(options: { prompt: string; create: boolean; edit: boolean; organize: boolean }): void {
    this.mutate(() => ({
      llmPrompt: options.prompt.trim(),
      llmChatCreateEnabled: options.create,
      llmChatEditEnabled: options.edit,
      llmChatOrganizeEnabled: options.organize,
    }));
  }

  /** Replace every connector value (missing keys become empty). */
  setNotifyValues(values: Readonly<Record<string, string>>): void {
    this.mutate(() => {
      const next: Record<string, string> = {};
      for (const key of NOTIFY_FIELD_KEYS) {
        next[key] = (values[key] ?? "").trim();
      }
      return { notifyValues: next };
    });
  }

  setReminderNotificationsEnabled(value: boolean): void {
    this.mutate(() => ({ reminderNotificationsEnabled: value }));
  }

  setDeviceNotificationsEnabled(value: boolean): void {
    this.mutate(() => ({ deviceNotificationsEnabled: value }));
  }

  addPaletteColor(name: string, light: string, dark: string): void {
    const l = normalizeHex(light);
    const d = normalizeHex(dark);
    if (!l || !d) {
      return;
    }
    const key = `custom-${Date.now()}-${this.customCounter++}`;
    this.mutate((s) => ({ palette: [...s.palette, { key, name: name.trim() || "Custom", light: l, dark: d }] }));
  }

  updatePaletteColor(key: string, changes: { name?: string; light?: string; dark?: string }): void {
    this.mutate((s) => ({
      palette: s.palette.map((e) =>
        e.key === key
          ? {
              ...e,
              name: changes.name ?? e.name,
              light: normalizeHex(changes.light) ?? e.light,
              dark: normalizeHex(changes.dark) ?? e.dark,
            }
          : e,
      ),
    }));
  }

  removePaletteColor(key: string): void {
    this.mutate((s) => ({ palette: s.palette.filter((e) => e.key !== key) }));
  }

  resetPalette(): void {
    this.mutate(() => ({ palette: DEFAULT_PALETTE }));
  }

  /** Drop the location reminders of deleted notes, keeping the document tidy. */
  removeLocationReminders(noteIds: ReadonlySet<string>): void {
    if (!this.state.locationReminders.some((r) => noteIds.has(String(r.note_id)))) {
      return;
    }
    this.mutate((s) => ({ locationReminders: s.locationReminders.filter((r) => !noteIds.has(String(r.note_id))) }));
  }

  dispose(): void {
    this.disposed = true;
    if (this.saveTimer !== null) {
      clearTimeout(this.saveTimer);
    }
  }
}
