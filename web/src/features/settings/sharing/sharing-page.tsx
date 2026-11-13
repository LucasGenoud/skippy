"use client";

import { Hint, SettingsSection } from "../kit/rows";
import { AiAccessSection } from "./ai-access-section";
import { PublicLinksSection } from "./public-links-section";

export function SharingPage() {
  return (
    <SettingsSection>
      <PublicLinksSection />
      <AiAccessSection />
      <Hint>A workspace&apos;s owner decides whether assistants can reach its notes.</Hint>
    </SettingsSection>
  );
}
