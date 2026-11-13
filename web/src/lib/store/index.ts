// The store layer in one import: hooks, controllers' types, and selectors.
export * from "./hooks";
export type { NotesState, NotesData, SyncStatus, EditPace, FinalizeMode, EditingStart, NotesStore } from "./notes-store";
export type { SettingsState, ThemeMode, AppFont, AppDateFormat, GridDensity, GridWidth, BoardExit, PaletteEntry, SettingsStore } from "./settings-store";
export {
  APP_FONTS,
  DATE_FORMATS,
  GRID_DENSITIES,
  GRID_WIDTHS,
  DEFAULT_PALETTE,
  DEFAULT_ACCENT,
  SETTINGS_DOCUMENT_MAX_BYTES,
  semanticSearchAvailable,
  llmConfigured,
  isManaged,
  notifyConfigured,
  configuredNotifyChannels,
  boardExitsFor,
  resolveNoteColor,
  formatClock,
  formatDate,
  reminderLabel,
  editedLabel,
} from "./settings-store";
export type { UiState, SemanticState, Destination, UiController } from "./ui-store";
export { selectionForDestination, isWorkspaceWide } from "./ui-store";
export type { AuthState, AuthStatus, AuthStore } from "./auth-store";
export type { Session } from "./session";
export type { LinkPreviewCache } from "./link-preview-cache";
export * from "./selectors";
