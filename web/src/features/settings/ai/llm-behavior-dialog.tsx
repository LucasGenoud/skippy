"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import type { UrlSummaryLength } from "@/lib/models";
import { useSettingsController } from "@/lib/store";
import { CheckRow } from "../kit/check-row";
import { Field, FormDialog, FormSectionLabel } from "../kit/form-dialog";

export const MAX_PROMPT_LENGTH = 4000;

const LENGTHS: readonly { value: UrlSummaryLength; label: string }[] = [
  { value: "short", label: "Brief" },
  { value: "medium", label: "Standard" },
  { value: "long", label: "Detailed" },
];

/** Custom instructions, link summaries, and which note changes chat may make. */
export function LlmBehaviorDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const settings = useSettingsController();
  const [initial] = useState(() => settings.state);
  const [prompt, setPrompt] = useState(initial.llmPrompt);
  const [create, setCreate] = useState(initial.llmChatCreateEnabled);
  const [edit, setEdit] = useState(initial.llmChatEditEnabled);
  const [organize, setOrganize] = useState(initial.llmChatOrganizeEnabled);
  const [summarize, setSummarize] = useState(initial.autoSummarizeLinks);
  const [length, setLength] = useState<UrlSummaryLength>(initial.linkSummaryLength);

  function save() {
    settings.setLlmBehavior({ prompt, create, edit, organize });
    settings.setLinkSummarySettings({ automatically: summarize, length });
    onOpenChange(false);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="AI behavior"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={save}>Save</Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Field
          label="Custom instructions"
          htmlFor="llm-prompt"
          helper={
            <span className="flex gap-2">
              <span className="flex-1">Used by chat, labeling, note editing, and summaries.</span>
              <span className="tabular-nums">
                {prompt.length}/{MAX_PROMPT_LENGTH}
              </span>
            </span>
          }
        >
          <Textarea
            id="llm-prompt"
            autoFocus
            rows={3}
            className="max-h-48"
            maxLength={MAX_PROMPT_LENGTH}
            value={prompt}
            placeholder="Example: Reply in French and keep notes concise."
            onChange={(e) => setPrompt(e.target.value)}
          />
        </Field>
        <div className="flex flex-col gap-1">
          <CheckRow title="Automatically summarize new links" subtitle="In text and Markdown notes" checked={summarize} onCheckedChange={setSummarize} />
          <Field label="Link summary length" htmlFor="llm-summary-length" className="px-2 pt-1">
            <Select value={length} onValueChange={(v) => setLength(v as UrlSummaryLength)}>
              <SelectTrigger id="llm-summary-length" className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {LENGTHS.map((l) => (
                  <SelectItem key={l.value} value={l.value}>
                    {l.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
        </div>
        <div className="flex flex-col gap-1">
          <FormSectionLabel className="px-2">Chat may</FormSectionLabel>
          <CheckRow title="Create notes" checked={create} onCheckedChange={setCreate} />
          <CheckRow title="Edit note content" checked={edit} onCheckedChange={setEdit} />
          <CheckRow title="Organize notes" subtitle="Pin, archive, trash, color, and reminders" checked={organize} onCheckedChange={setOrganize} />
        </div>
      </div>
    </FormDialog>
  );
}
