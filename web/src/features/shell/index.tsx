"use client";

import type { ReactNode } from "react";

// Placeholder: the SHELL agent replaces this with the sidebar and top bar.
export function AppShell({ children }: { children: ReactNode }) {
  return <div className="flex min-h-dvh flex-col">{children}</div>;
}
