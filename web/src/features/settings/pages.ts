"use client";

import { Bell, Info, Link2, Package, Palette, Sparkles, User, type LucideIcon } from "lucide-react";
import { SETTINGS_PAGES, type SettingsPageId } from "@/lib/router";
import { GRID_DENSITIES, llmConfigured, notifyConfigured, useAuth, useSettings, type SettingsState } from "@/lib/store";
import { CLIENT_VERSION } from "./kit/version";

// The settings pages (`SettingsPage` in settings_pages.dart): grouped by what
// someone comes looking for, each with an icon and a one-line summary of where
// things stand. Workspace settings live on each workspace's own page.

export const PAGE_ICONS: Record<SettingsPageId, LucideIcon> = {
  account: User,
  appearance: Palette,
  reminders: Bell,
  ai: Sparkles,
  sharing: Link2,
  data: Package,
  about: Info,
};

export const pageTitle = (page: SettingsPageId): string => SETTINGS_PAGES.find((p) => p.id === page)?.title ?? "Settings";

const THEME_NAMES = { system: "Automatic", light: "Light", dark: "Dark" } as const;

/** The summary for every page but Account, from the settings state. */
export function settingsSummary(page: Exclude<SettingsPageId, "account">, s: SettingsState): string {
  switch (page) {
    case "appearance": {
      const density = GRID_DENSITIES.find((d) => d.id === s.gridDensity)?.label ?? "";
      return `${THEME_NAMES[s.themeMode]} theme · ${density} grid`;
    }
    case "reminders":
      // The web has no device notifications or places; push is all there is.
      return notifyConfigured(s) && s.reminderNotificationsEnabled ? "Push" : "Not delivered anywhere yet";
    case "ai":
      return llmConfigured(s) ? `Provider: ${s.llmModel}` : "No AI provider yet";
    case "sharing":
      return "Public links and assistant tokens";
    case "data":
      return "Backup, restore, Google Keep, export";
    case "about":
      return `Version ${CLIENT_VERSION}`;
  }
}

/** One line on where [page] stands, shown under its name in the index. */
export function usePageSummary(page: SettingsPageId): string {
  const email = useAuth((s) => s.user?.email ?? null);
  const summary = useSettings((s) => (page === "account" ? "" : settingsSummary(page, s)));
  return page === "account" ? (email ?? "Your name, email, and password") : summary;
}
