"use client";

import type { SettingsPageId } from "@/lib/router";

// Placeholder: the SETTINGS agent replaces this.
export function SettingsScreen({ page }: { page?: SettingsPageId }) {
  return <div data-placeholder="settings" data-page={page ?? ""} />;
}
