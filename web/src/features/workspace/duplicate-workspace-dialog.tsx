"use client";

import { useId, useState } from "react";
import { LoaderCircle } from "lucide-react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { Reveal } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Progress } from "@/components/ui/progress";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import type { WorkspaceCopyContent } from "@/lib/models";
import { useNotesController, useWorkspace } from "@/lib/store";
import { Field, FormDialog, FormSectionLabel } from "@/features/settings/kit/form-dialog";
import { SwitchRow } from "@/features/settings/kit/rows";
import { useOpenKey } from "@/features/settings/kit/use-open-key";
import { MAX_WORKSPACE_NAME } from "./workspace-dialogs";

/** Room left for " copy" inside the name limit. */
const COPY_NAME_PREFIX = 55;

/** "Groceries copy", the original's name cut to leave room for the suffix. */
export function copyName(name: string): string {
  return `${Array.from(name).slice(0, COPY_NAME_PREFIX).join("")} copy`;
}

export interface DuplicateWorkspaceDialogProps {
  workspaceId: string;
  open: boolean;
  onOpenChange(open: boolean): void;
}

/** Copies a workspace's structure, or structure and notes, into a new one the caller owns. */
export function DuplicateWorkspaceDialog(props: DuplicateWorkspaceDialogProps) {
  // A fresh form each time it opens.
  const key = useOpenKey(props.open);
  return <DuplicateForm key={key} {...props} />;
}

const CONTENT_OPTIONS: readonly { value: WorkspaceCopyContent; title: string; subtitle: string }[] = [
  { value: "structure", title: "Structure only", subtitle: "Collections, layouts, columns, labels and smart views." },
  { value: "notes", title: "Structure and notes", subtitle: "Also includes archived notes and attachments." },
];

function DuplicateForm({ workspaceId, open, onOpenChange }: DuplicateWorkspaceDialogProps) {
  const notes = useNotesController();
  const workspace = useWorkspace(workspaceId);
  const ids = useId();
  const [name, setName] = useState(() => copyName(workspace?.name ?? ""));
  const [content, setContent] = useState<WorkspaceCopyContent>("structure");
  const [reminders, setReminders] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nameError, setNameError] = useState<string | null>(null);

  async function copy() {
    if (busy) {
      return;
    }
    if (!name.trim()) {
      setNameError("Enter a name");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await notes.duplicateWorkspace(workspaceId, name.trim(), content, { reminders });
      onOpenChange(false);
    } catch {
      setBusy(false);
      setError("Could not duplicate workspace. Check your connection and try again.");
    }
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Duplicate workspace"
      busy={busy}
      onSubmit={() => void copy()}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void copy()} disabled={busy}>
            {busy ? <LoaderCircle aria-hidden className="animate-spin" /> : null}
            {busy ? "Duplicating…" : "Duplicate"}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Field label="Name" htmlFor={`${ids}-name`} error={nameError}>
          <Input
            id={`${ids}-name`}
            autoFocus
            disabled={busy}
            maxLength={MAX_WORKSPACE_NAME}
            value={name}
            aria-invalid={nameError !== null || undefined}
            onChange={(e) => {
              setName(e.target.value);
              setNameError(null);
            }}
          />
        </Field>
        <div className="flex flex-col gap-2">
          <FormSectionLabel>Include</FormSectionLabel>
          <RadioGroup value={content} onValueChange={(v) => setContent(v as WorkspaceCopyContent)} disabled={busy} className="gap-1">
            {CONTENT_OPTIONS.map((o) => (
              <label key={o.value} htmlFor={`${ids}-${o.value}`} className="flex cursor-pointer items-start gap-3 rounded-md px-2 py-2 transition-colors duration-150 ease-standard hover:bg-hover">
                <RadioGroupItem id={`${ids}-${o.value}`} value={o.value} className="mt-0.5" />
                <span className="flex flex-col">
                  <span className="text-sm text-on-surface">{o.title}</span>
                  <span className="text-xs text-on-surface-variant">{o.subtitle}</span>
                </span>
              </label>
            ))}
          </RadioGroup>
          <Reveal>
            {content === "notes" ? (
              <SwitchRow title="Copy reminders" subtitle="Keep scheduled reminders in the copied notes." checked={reminders} onCheckedChange={busy ? undefined : setReminders} />
            ) : null}
          </Reveal>
        </div>
        <p className="border-t border-hairline pt-4 text-xs text-on-surface-variant">You own the copy. Sharing, trash and version history stay in the original workspace.</p>
        <Reveal>{busy ? <Progress aria-label="Duplicating" value={8} className="animate-pulse" /> : null}</Reveal>
        <AnimatedFormError message={error} className="pt-0" />
      </div>
    </FormDialog>
  );
}
