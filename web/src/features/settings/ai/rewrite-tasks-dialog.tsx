"use client";

import { useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { Plus, Trash2 } from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import type { NoteRewriteTask } from "@/lib/models";
import { useSettingsController } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { Field, FormDialog } from "../kit/form-dialog";
import { useDialog } from "../kit/use-dialog";
import { MAX_PROMPT_LENGTH } from "./llm-behavior-dialog";

const MAX_NAME_LENGTH = 64;

/** A fresh id for a task the user adds. */
export const customTaskId = (now: number = Date.now()): string => `custom-${now * 1000}`;

/** The rewrite actions every note menu offers; edited as a list, saved together. */
export function RewriteTasksDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const settings = useSettingsController();
  const reduced = useReducedMotion();
  const [tasks, setTasks] = useState<readonly NoteRewriteTask[]>(() => settings.state.llmRewriteTasks);
  const editor = useDialog<{ index: number | null }>();

  function save() {
    settings.setLlmRewriteTasks(tasks);
    onOpenChange(false);
  }

  function apply(index: number | null, task: NoteRewriteTask) {
    setTasks((list) => (index === null ? [...list, task] : list.map((t, i) => (i === index ? task : t))));
  }

  const editing = editor.value?.index ?? null;

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="AI rewrite tasks"
      description="These actions appear in each note menu. Language, note format, and response-safety instructions are added automatically."
      width="wide"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={save}>Save</Button>
        </>
      }
    >
      <ul className="flex flex-col gap-0.5">
        <AnimatePresence initial={false}>
          {tasks.map((task, i) => (
            <motion.li
              key={task.id}
              layout
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: "auto" }}
              exit={{ opacity: 0, height: 0 }}
              transition={transitionFor(TRANSITION.base, reduced)}
              className="overflow-hidden"
            >
              <div className="flex items-center gap-2 rounded-md px-2 py-1.5 transition-colors duration-150 ease-standard hover:bg-hover">
                <button type="button" className="flex min-w-0 flex-1 flex-col rounded-md text-left outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50" onClick={() => editor.show({ index: i })}>
                  <span className="truncate text-sm text-on-surface">{task.name}</span>
                  <span className="line-clamp-2 text-xs text-on-surface-variant">{task.prompt}</span>
                </button>
                <IconButton size="sm" label={`Remove ${task.name}`} icon={<Trash2 />} onClick={() => setTasks((list) => list.filter((t) => t.id !== task.id))} />
              </div>
            </motion.li>
          ))}
        </AnimatePresence>
      </ul>
      <Button variant="outline" size="sm" className="mt-3" onClick={() => editor.show({ index: null })}>
        <Plus aria-hidden />
        Add task
      </Button>
      {editor.value ? (
        <RewriteTaskDialog
          key={editor.key}
          task={editing === null ? null : (tasks[editing] ?? null)}
          open={editor.open}
          onOpenChange={editor.onOpenChange}
          onSave={(task) => apply(editing, task)}
        />
      ) : null}
    </FormDialog>
  );
}

function RewriteTaskDialog({
  task,
  open,
  onOpenChange,
  onSave,
}: {
  task: NoteRewriteTask | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSave: (task: NoteRewriteTask) => void;
}) {
  const [name, setName] = useState(task?.name ?? "");
  const [prompt, setPrompt] = useState(task?.prompt ?? "");

  function save() {
    const n = name.trim();
    const p = prompt.trim();
    if (!n || !p) {
      return;
    }
    onSave({ id: task?.id ?? customTaskId(), name: n, prompt: p });
    onOpenChange(false);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title={task === null ? "Add rewrite task" : "Edit rewrite task"}
      width="wide"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={save} disabled={!name.trim() || !prompt.trim()}>
            Save
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Field label="Task name" htmlFor="rewrite-name">
          <Input id="rewrite-name" autoFocus maxLength={MAX_NAME_LENGTH} value={name} onChange={(e) => setName(e.target.value)} />
        </Field>
        <Field label="Prompt" htmlFor="rewrite-prompt" helper={`${prompt.length}/${MAX_PROMPT_LENGTH}`}>
          <Textarea id="rewrite-prompt" rows={5} className="max-h-72" maxLength={MAX_PROMPT_LENGTH} value={prompt} onChange={(e) => setPrompt(e.target.value)} />
        </Field>
      </div>
    </FormDialog>
  );
}
