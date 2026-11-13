"use client";

import { ImageUp, Keyboard, Mic, ScanSearch, Server, Monitor } from "lucide-react";
import { useSettings } from "@/lib/store";
import { SettingsRow, SettingsSection } from "../kit/rows";
import { CLIENT_VERSION } from "../kit/version";
import { openShortcutHelp } from "@/features/shell/shortcut-help";

const NOT_SET_UP = "Not set up on this server";

export function AboutPage() {
  const serverVersion = useSettings((s) => s.serverVersion);
  const search = useSettings((s) => s.semanticSearchCapable);
  const audio = useSettings((s) => s.audioTranscriptionCapable);
  const ocr = useSettings((s) => s.imageOcrCapable);

  return (
    <>
      <SettingsSection>
        <SettingsRow icon={Monitor} title="Client version" subtitle={CLIENT_VERSION} />
        <SettingsRow icon={Server} title="Server version" subtitle={serverVersion ?? "Unavailable"} />
      </SettingsSection>
      <SettingsSection title="This server">
        <SettingsRow icon={ScanSearch} title="Semantic search" subtitle={search ? "Finds notes by meaning" : NOT_SET_UP} />
        <SettingsRow
          icon={Mic}
          title="Voice transcription"
          subtitle={audio ? "Whisper transcribes audio notes" : "Not set up: audio notes record and play without a transcript"}
        />
        <SettingsRow icon={ImageUp} title="Text in images" subtitle={ocr ? "Words in pictures are read so search can find them" : NOT_SET_UP} />
      </SettingsSection>
      <SettingsSection>
        <SettingsRow icon={Keyboard} title="Keyboard shortcuts" subtitle="Also opens with ? on the notes screen" onClick={openShortcutHelp} />
      </SettingsSection>
    </>
  );
}
