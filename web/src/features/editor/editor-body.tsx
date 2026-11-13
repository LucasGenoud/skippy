"use client";

import { useCallback, useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type Ref } from "react";
import { CircleAlert, Sparkles, Trash2 } from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { cn } from "cn";

import { Reveal } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import type { ReminderValue } from "@/components/common/reminder-picker";
import { REPEAT_LABELS } from "@/components/common/reminder-format";
import { AbortedError } from "@/lib/api/errors";
import { audioClip, makeNote, isTranscribing, transcriptFailed, type ChecklistItem, type Label, type Note, type NoteKind, type NotePattern, type NoteRewriteTask } from "@/lib/models/note";
import { navigate } from "@/lib/router";
import { normalizeDepths, removeItem, shiftDepth } from "@/lib/state/checklist-tree";
import { EditorHistory, type EditKind, type EditorSnapshot } from "@/lib/state/editor-history";
import { findNoteLinks, noteLinkTitle, noteLinkToken } from "@/lib/state/note-links";
import {
  editedLabel,
  reminderLabel,
  useApi,
  useBacklinkIds,
  useIsDraft,
  useIsRewriting,
  useNote,
  useNoteAvailability,
  useNotesController,
  useNotesSelector,
  useSettings,
  useSettingsController,
} from "@/lib/store";
import { DURATION, TRANSITION, transitionFor } from "@/lib/theme/motion";
import { newId } from "@/lib/util/id";
import { mimeFromName, pastedFileName } from "@/lib/util/mime";
import { AudioPlayer } from "@/features/notes/audio-player";
import { LinkSummaryIndicator } from "@/features/notes/link-summary-indicator";
import { NoteMarkdown } from "@/features/notes/note-markdown";
import { filesWithinLimit, rewriteWithAi, toggleArchive } from "@/features/notes/note-actions";
import { PresenceRow, StateCrossFade } from "@/features/notes/motion-kit";
import { TranscribingIndicator, TranscriptFailed } from "@/features/notes/transcribing-indicator";
import { ChecklistEditor } from "./checklist/checklist-editor";
import { matchingRows } from "./checklist/checklist-view";
import { findMatches } from "./lib/body-segments";
import { useBrightness } from "./lib/hooks";
import { applyMarkdownAction, setTaskLine, type MarkdownAction } from "./lib/markdown-format";
import { AttachmentTiles, type PendingUpload } from "./parts/attachments";
import { BodyField, type BodyFieldHandle } from "./parts/body-field";
import { BottomBar } from "./parts/bottom-bar";
import { MarkdownToolbar } from "./parts/markdown-toolbar";
import { LinkPreviews, MetaChips, linkPreviewUrls } from "./parts/note-extras";
import { NoteLinkPicker, NoteLinksSection, type LinkedNoteRef } from "./parts/note-links";
import { TopBar } from "./parts/top-bar";
import { ShareDialog } from "./share-dialog";

// Everything inside the editor's surface (`_EditorScreenState`): the fields,
// the session's undo history, and every action on the note. Keystrokes stay
// here: the fields are uncontrolled, and each edit goes to the store at the
// typing pace, which throttles notifications so the grid never re-renders per
// key (the open card is frozen anyway).

const TRASH_HINT = "Can't edit in Trash, restore the note first";
const SUMMARY_ADDED = "Page summary added";

/** Imperative hooks the surrounding shell needs. */
export interface EditorBodyHandle {
  /** Escape was pressed: true when something inside took it. */
  escape(): boolean;
  /** Ctrl/Cmd shortcuts: true when handled. */
  shortcut(event: globalThis.KeyboardEvent): boolean;
  /** The open animation has finished. */
  opened(): void;
}

function snapshotOf(note: Note): EditorSnapshot {
  return { kind: note.kind, title: note.title, content: note.content, items: note.items };
}

function labelsEqual(a: readonly Label[], b: readonly Label[]): boolean {
  return a.length === b.length && a.every((l, i) => l === b[i]);
}

function fitTitle(element: HTMLTextAreaElement | null): void {
  if (!element) {
    return;
  }
  element.style.height = "auto";
  element.style.height = `${element.scrollHeight}px`;
}

/** The text that carries a note's links: title, body and rows. */
function noteLinkText(note: Note): string {
  return [note.title, note.content, ...note.items.map((i) => i.text)].join("\n");
}

export function EditorBody({
  noteId,
  wide,
  onClose,
  handleRef,
}: {
  noteId: string;
  wide: boolean;
  onClose(): void;
  handleRef: Ref<EditorBodyHandle>;
}) {
  const notes = useNotesController();
  const settingsStore = useSettingsController();
  const api = useApi();
  const note = useNote(noteId);
  const can = useNoteAvailability(noteId);
  const rewriting = useIsRewriting(noteId);
  const isDraft = useIsDraft(noteId);
  const use24h = useSettings((s) => s.use24hTime);
  const palette = useSettings((s) => s.palette);
  const brightness = useBrightness();
  const backlinkIds = useBacklinkIds(noteId);
  const reduced = useReducedMotion();
  const labels = useNotesSelector(
    (s) => {
      const n = s.notes[noteId];
      if (!n) {
        return [];
      }
      return s.labels.filter((l) => n.labelIds.includes(l.id)).sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
    },
    labelsEqual,
    [noteId],
  );

  const title = useRef<HTMLTextAreaElement>(null);
  const body = useRef<BodyFieldHandle>(null);
  // Two body fields overlap while one cross-fades into the other; the one
  // leaving must not clear the handle of the one that replaced it.
  const bindBody = useCallback((handle: BodyFieldHandle | null) => {
    if (!handle) {
      return;
    }
    body.current = handle;
    return () => {
      if (body.current === handle) {
        body.current = null;
      }
    };
  }, []);
  const imageInput = useRef<HTMLInputElement>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const restoring = useRef(false);
  // Undo belongs to this editor session; it starts from the note as opened.
  const [history] = useState(() => new EditorHistory(snapshotOf(notes.noteById(noteId) ?? makeNote({ id: noteId }))));
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const startedNew = useRef(isDraft);
  // Existing markdown opens rendered; a new markdown draft opens as source.
  const [preview, setPreview] = useState(() => note?.kind === "markdown" && !isDraft);
  const [finding, setFinding] = useState(false);
  const [findQuery, setFindQuery] = useState("");
  const [findIndex, setFindIndex] = useState(0);
  const [bodyFocused, setBodyFocused] = useState(false);
  const [linkQuery, setLinkQuery] = useState<string | null>(null);
  const [linkActive, setLinkActive] = useState(0);
  const [uploads, setUploads] = useState<readonly PendingUpload[]>([]);
  const [summarizing, setSummarizing] = useState<ReadonlySet<string>>(() => new Set());
  const summaryAborts = useRef(new Map<string, AbortController>());
  const [composerFocus, setComposerFocus] = useState(0);
  const [shareOpen, setShareOpen] = useState(false);
  const [dropping, setDropping] = useState(false);

  const kind: NoteKind = note?.kind ?? "text";
  const trashed = note?.trashed ?? false;
  const readOnly = trashed || rewriting;

  // -- history ------------------------------------------------------------------

  const latestNote = useCallback((): Note | null => notes.noteById(noteId), [notes, noteId]);

  const record = useCallback(
    (editKind: EditKind): void => {
      const current = latestNote();
      if (restoring.current || !current || false) {
        return;
      }
      history.record(snapshotOf(current), editKind);
      setCanUndo(history.canUndo);
      setCanRedo(history.canRedo);
    },
    [latestNote, history],
  );

  const applySnapshot = (snapshot: EditorSnapshot): void => {
    restoring.current = true;
    if (document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    if (title.current) {
      title.current.value = snapshot.title;
      fitTitle(title.current);
    }
    body.current?.setText(snapshot.content);
    notes.updateNoteContent(noteId, { kind: snapshot.kind, title: snapshot.title, content: snapshot.content, items: snapshot.items });
    history.resetTo(snapshot);
    restoring.current = false;
    setCanUndo(history.canUndo);
    setCanRedo(history.canRedo);
  };

  const undo = (): void => {
    const current = latestNote();
    const previous = current && history.undo(snapshotOf(current));
    if (previous) {
      applySnapshot(previous);
    }
  };

  const redo = (): void => {
    const current = latestNote();
    const next = current && history.redo(snapshotOf(current));
    if (next) {
      applySnapshot(next);
    }
  };

  // -- text fields ----------------------------------------------------------------

  const onTitleInput = (value: string): void => {
    const current = latestNote();
    if (restoring.current || !current || current.title === value) {
      return;
    }
    notes.updateNoteContent(noteId, { title: value, pace: "typing" });
    record("typing");
  };

  const onBodyText = (value: string): void => {
    const current = latestNote();
    if (restoring.current || !current || current.kind === "checklist" || current.content === value) {
      return;
    }
    notes.updateNoteContent(noteId, { content: value, pace: "typing" });
    record("typing");
  };

  // Edits from elsewhere (another device, a version restore, a rewrite) reach
  // a field only while the caret is away from it.
  const noteTitle = note?.title;
  const noteContent = note?.content;
  useEffect(() => {
    const el = title.current;
    if (el && noteTitle !== undefined && document.activeElement !== el && el.value !== noteTitle) {
      el.value = noteTitle;
      fitTitle(el);
    }
  }, [noteTitle]);
  useEffect(() => {
    const field = body.current;
    if (!field || noteContent === undefined || document.activeElement === field.element()) {
      return;
    }
    if (field.getText() !== noteContent) {
      field.setText(noteContent);
    }
  }, [noteContent]);
  useLayoutEffect(() => fitTitle(title.current), []);

  // -- checklist ------------------------------------------------------------------

  const items = (): readonly ChecklistItem[] => latestNote()?.items ?? [];

  const setItems = (next: readonly ChecklistItem[], editKind: EditKind = "discrete"): void => {
    notes.updateNoteContent(noteId, { items: next, pace: editKind === "typing" ? "typing" : undefined });
    record(editKind);
  };

  const checklist = {
    add(text: string): string {
      const current = items();
      // A new row continues the list at the depth it left off.
      const item: ChecklistItem = { id: newId(), text: text.trim(), done: false, depth: current[current.length - 1]?.depth ?? 0 };
      setItems([...current, item]);
      return item.id;
    },
    insertAfter(afterId: string): string {
      const current = [...items()];
      const index = current.findIndex((i) => i.id === afterId);
      const item: ChecklistItem = { id: newId(), text: "", done: false, depth: index < 0 ? 0 : (current[index]?.depth ?? 0) };
      current.splice(index < 0 ? current.length : index + 1, 0, item);
      setItems(current);
      return item.id;
    },
    text(itemId: string, text: string): void {
      setItems(
        items().map((i) => (i.id === itemId ? { ...i, text } : i)),
        "typing",
      );
    },
    toggle(itemId: string): void {
      notes.toggleChecklistItem(noteId, itemId);
      record("discrete");
    },
    remove(itemId: string): void {
      // Subtasks are promoted rather than deleted with their task.
      setItems(removeItem(items(), itemId));
    },
    clearChecked(): void {
      setItems(normalizeDepths(items().filter((i) => !i.done)));
    },
    indent(itemId: string, delta: number): void {
      setItems(shiftDepth(items(), itemId, delta));
    },
  };

  // -- find -------------------------------------------------------------------------

  const findMatchesNow = useMemo(() => {
    if (!finding || !note) {
      return { count: 0, rows: [] as string[] };
    }
    if (note.kind === "checklist") {
      const rows = matchingRows(note.items, findQuery);
      return { count: rows.length, rows };
    }
    return { count: findMatches(note.content, findQuery).length, rows: [] as string[] };
  }, [finding, note, findQuery]);
  const matchIndex = findMatchesNow.count === 0 ? 0 : Math.min(findIndex, findMatchesNow.count - 1);

  const openFind = (): void => {
    setFinding(true);
    setFindIndex(0);
  };
  const closeFind = (): void => {
    setFinding(false);
    setFindQuery("");
  };
  const findStep = (step: 1 | -1): void => {
    const count = findMatchesNow.count;
    if (count > 0) {
      setFindIndex((i) => (((Math.min(i, count - 1) + step) % count) + count) % count);
    }
  };

  // -- note links -------------------------------------------------------------------

  const linkCandidates = linkQuery === null || readOnly ? [] : notes.linkTargets(linkQuery, noteId);

  const insertNoteLink = (target: Note): void => {
    const field = body.current;
    if (linkQuery === null || !field) {
      return;
    }
    const caret = field.selection().start;
    const start = caret - linkQuery.length - 2;
    const token = noteLinkToken(target.id, noteLinkTitle(target));
    const text = field.getText();
    const inserted = text[caret] === " " ? token : `${token} `;
    field.replaceRange(start, caret, inserted);
    setLinkQuery(null);
  };

  const bodyKey = (event: KeyboardEvent<HTMLTextAreaElement>): boolean => {
    if (linkQuery === null || linkCandidates.length === 0 || event.nativeEvent.isComposing) {
      return false;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const step = event.key === "ArrowDown" ? 1 : -1;
      setLinkActive((i) => (i + step + linkCandidates.length) % linkCandidates.length);
      return true;
    }
    if (event.key === "Enter" || event.key === "Tab") {
      const target = linkCandidates[Math.min(linkActive, linkCandidates.length - 1)];
      if (target) {
        insertNoteLink(target);
        return true;
      }
    }
    return false;
  };

  const openLinkedNote = (id: string): void => navigate({ name: "note", noteId: id });

  const outgoing: LinkedNoteRef[] = [];
  if (note) {
    const seen = new Set<string>();
    for (const link of findNoteLinks(note.content)) {
      if (link.noteId === note.id || seen.has(link.noteId)) {
        continue;
      }
      seen.add(link.noteId);
      const live = notes.linkTitleFor(link.noteId);
      outgoing.push({ id: link.noteId, title: live ?? link.title, reachable: live !== null });
    }
  }
  const incoming: LinkedNoteRef[] = backlinkIds
    .map((id) => notes.noteById(id))
    .filter((n): n is Note => n !== null)
    .map((n) => ({ id: n.id, title: noteLinkTitle(n), reachable: true }));

  // -- markdown ---------------------------------------------------------------------

  const formatMarkdown = (action: MarkdownAction): void => {
    const field = body.current;
    if (!field) {
      return;
    }
    const sel = field.selection();
    const text = field.getText();
    const edit = applyMarkdownAction({ text, start: sel.start, end: sel.end }, action);
    // Rewrite only the changed span, so the browser keeps the rest as typed.
    let head = 0;
    while (head < text.length && head < edit.text.length && text[head] === edit.text[head]) {
      head++;
    }
    let tail = 0;
    while (tail < text.length - head && tail < edit.text.length - head && text[text.length - 1 - tail] === edit.text[edit.text.length - 1 - tail]) {
      tail++;
    }
    field.replaceRange(head, text.length - tail, edit.text.slice(head, edit.text.length - tail), { start: edit.start, end: edit.end });
  };

  const setMarkdownPreview = (next: boolean): void => {
    setPreview(next);
    if (!next) {
      requestAnimationFrame(() => body.current?.focus());
    }
  };

  const toggleTask = (lineIndex: number, done: boolean): void => {
    const current = latestNote();
    if (!current || trashed) {
      return;
    }
    const content = setTaskLine(current.content, lineIndex, done);
    body.current?.setText(content);
    notes.updateNoteContent(noteId, { content });
    record("discrete");
  };

  // -- note actions -----------------------------------------------------------------

  const convert = (target: NoteKind): void => {
    notes.convertKind(noteId, target);
    record("discrete");
    setPreview(false);
  };

  const rewrite = async (task: NoteRewriteTask): Promise<void> => {
    if (!can.canRewrite || rewriting) {
      return;
    }
    if (!(await rewriteWithAi(notes, noteId, task))) {
      return;
    }
    const updated = latestNote();
    if (updated) {
      restoring.current = true;
      if (title.current) {
        title.current.value = updated.title;
        fitTitle(title.current);
      }
      if (updated.kind !== "checklist") {
        body.current?.setText(updated.content);
      }
      restoring.current = false;
    }
    record("discrete");
  };

  const archive = (): void => {
    const current = latestNote();
    if (!current || !can.canArchive) {
      return;
    }
    onClose();
    toggleArchive(notes, current);
  };

  const restore = (): void => {
    notes.restoreFromTrash(noteId);
    onClose();
  };

  const deleteForever = (): void => {
    onClose();
    notes.deleteForever(noteId);
    showAppSnack("Note deleted forever", { icon: Trash2, kind: "danger" });
  };

  const share = (): void => {
    const current = latestNote();
    if (!current || (current.title.trim() === "" && current.content.trim() === "" && current.items.length === 0 && current.attachments.length === 0)) {
      showAppSnack("Add some content before sharing");
      return;
    }
    setShareOpen(true);
  };

  const setReminder = (value: ReminderValue | null): void => {
    notes.setReminder(noteId, value?.at ?? null, value?.repeat ?? null);
  };

  // -- files ------------------------------------------------------------------------

  const uploadAll = async (files: readonly File[], failure: string): Promise<void> => {
    const accepted = filesWithinLimit(files);
    if (accepted.length === 0) {
      return;
    }
    for (const file of accepted) {
      const mime = file.type || mimeFromName(file.name);
      const preview = mime.startsWith("image/") ? URL.createObjectURL(file) : null;
      const pending: PendingUpload = { key: newId(), name: file.name, mime, size: file.size, previewUrl: preview };
      setUploads((u) => [...u, pending]);
      try {
        await notes.uploadFile(noteId, file, mime, file.name);
      } catch {
        showAppSnack(failure, { icon: CircleAlert, kind: "danger" });
        return;
      } finally {
        setUploads((u) => u.filter((x) => x !== pending));
        if (preview) {
          // After the tile has faded out.
          setTimeout(() => URL.revokeObjectURL(preview), DURATION.slow * 2);
        }
      }
    }
  };

  const uploadRef = useRef(uploadAll);
  useLayoutEffect(() => {
    uploadRef.current = uploadAll;
  });

  // Files on the clipboard attach to this note; a plain text paste is left alone.
  useEffect(() => {
    if (trashed) {
      return;
    }
    const onPaste = (event: ClipboardEvent): void => {
      const data = event.clipboardData;
      if (!data) {
        return;
      }
      let files = Array.from(data.files);
      if (files.length === 0) {
        files = Array.from(data.items)
          .filter((item) => item.kind === "file")
          .map((item) => item.getAsFile())
          .filter((f): f is File => f !== null);
      }
      if (files.length === 0) {
        return;
      }
      event.preventDefault();
      event.stopImmediatePropagation();
      const named = files.map((f) => new File([f], pastedFileName(f.type || mimeFromName(f.name), f.name), { type: f.type }));
      void uploadRef.current(named, "Couldn't upload the pasted files");
    };
    window.addEventListener("paste", onPaste, true);
    return () => window.removeEventListener("paste", onPaste, true);
  }, [trashed]);

  // -- summaries ----------------------------------------------------------------------

  useEffect(() => {
    const aborts = summaryAborts.current;
    return () => aborts.forEach((a) => a.abort());
  }, []);

  const summarize = async (url: string): Promise<void> => {
    if (summaryAborts.current.has(url)) {
      return;
    }
    const abort = new AbortController();
    summaryAborts.current.set(url, abort);
    setSummarizing(new Set(summaryAborts.current.keys()));
    try {
      const summary = (await api.summarizeUrl(url, { noteId, length: settingsStore.state.linkSummaryLength, signal: abort.signal })).trim();
      if (abort.signal.aborted || summary === "") {
        return;
      }
      const current = (body.current?.getText() ?? latestNote()?.content ?? "").trimEnd();
      const content = current === "" ? summary : `${current}\n\n${summary}`;
      body.current?.setText(content, "end");
      notes.updateNoteContent(noteId, { content });
      record("discrete");
      showAppSnack(SUMMARY_ADDED, { icon: Sparkles });
    } catch (error) {
      if (!abort.signal.aborted && !(error instanceof AbortedError)) {
        showAppSnack("Couldn't summarize page", { icon: CircleAlert, kind: "danger" });
      }
    } finally {
      if (summaryAborts.current.get(url) === abort) {
        summaryAborts.current.delete(url);
      }
      setSummarizing(new Set(summaryAborts.current.keys()));
    }
  };

  const stopSummarizing = (url: string): void => {
    const abort = summaryAborts.current.get(url);
    if (!abort) {
      return;
    }
    summaryAborts.current.delete(url);
    abort.abort();
    setSummarizing(new Set(summaryAborts.current.keys()));
  };

  // -- the shell's hooks ----------------------------------------------------------------

  useImperativeHandle(handleRef, () => ({
    escape() {
      if (linkQuery !== null) {
        setLinkQuery(null);
        return true;
      }
      if (finding) {
        closeFind();
        return true;
      }
      return false;
    },
    shortcut(event) {
      const mod = event.metaKey || event.ctrlKey;
      if (!mod || event.altKey) {
        return false;
      }
      const key = event.key.toLowerCase();
      if (key === "f") {
        openFind();
        return true;
      }
      const inFind = event.target instanceof HTMLElement && event.target.getAttribute("aria-label") === "Find in note";
      if (inFind || trashed) {
        return false;
      }
      if (key === "z" && !event.shiftKey) {
        undo();
        return true;
      }
      if ((key === "z" && event.shiftKey) || (key === "y" && event.ctrlKey)) {
        redo();
        return true;
      }
      return false;
    },
    opened() {
      // A brand-new note opens on its title, once the morph has settled.
      if (startedNew.current && !trashed) {
        title.current?.focus();
      }
    },
  }));

  if (!note) {
    return null;
  }

  const clip = audioClip(note);
  const urls = linkPreviewUrls(noteLinkText(note));
  const reminder: ReminderValue | null = note.reminderAt ? { at: note.reminderAt, repeat: note.reminderRepeat ?? undefined } : null;
  const reminderText = note.reminderAt
    ? `${reminderLabel(note.reminderAt, settingsStore.state)}${note.reminderRepeat ? ` · ${REPEAT_LABELS[note.reminderRepeat]}` : ""}`
    : "";
  const formatBar = kind === "markdown" && bodyFocused && !preview && !finding && !trashed;
  const findQueryLive = finding ? findQuery : "";

  const tapBelow = (): void => {
    if (readOnly) {
      return;
    }
    if (kind === "checklist") {
      setComposerFocus((n) => n + 1);
    } else if (kind === "text" || (kind === "markdown" && !preview)) {
      body.current?.focus("end");
    }
  };

  const bodyField = (markdown: boolean, placeholder: string) => (
    <BodyField
      key={markdown ? "markdown" : "text"}
      ref={bindBody}
      initialText={note.content}
      markdown={markdown}
      readOnly={readOnly}
      placeholder={placeholder}
      findQuery={findQueryLive}
      currentMatch={finding ? matchIndex : -1}
      onTextChange={onBodyText}
      onLinkQuery={(q) => {
        setLinkQuery(q);
        setLinkActive(0);
      }}
      onFocusChange={setBodyFocused}
      onKeyDown={bodyKey}
      onReadOnlyTap={() => trashed && showAppSnack(TRASH_HINT)}
    />
  );

  let content;
  if (kind === "audio") {
    content = (
      <div className="flex flex-col">
        {clip ? (
          <div className="py-3">
            <AudioPlayer noteId={noteId} attachmentId={clip.id} variant="editor" />
          </div>
        ) : null}
        {/* Transcribing, failed and the transcript come and go as the server works; each grows in or out. */}
        <AnimatePresence initial={false}>
          {isTranscribing(note) ? (
            <PresenceRow key="transcribing">
              <div className="py-2">
                <TranscribingIndicator />
              </div>
            </PresenceRow>
          ) : null}
          {!isTranscribing(note) && transcriptFailed(note) ? (
            <PresenceRow key="failed">
              <div className="py-1">
                <TranscriptFailed onRetry={trashed ? undefined : () => notes.retranscribe(noteId)} />
              </div>
            </PresenceRow>
          ) : null}
          {!isTranscribing(note) ? <PresenceRow key="transcript">{bodyField(false, "Transcript")}</PresenceRow> : null}
        </AnimatePresence>
      </div>
    );
  } else if (kind === "checklist") {
    content = (
      <ChecklistEditor
        items={note.items}
        reminders={note.itemReminders}
        readOnly={readOnly}
        findQuery={findQueryLive}
        currentMatchId={finding ? (findMatchesNow.rows[matchIndex] ?? null) : null}
        use24h={use24h}
        composerFocus={composerFocus}
        suggestionsFor={(q, exclude) => notes.suggestionsFor(noteId, q, exclude)}
        latestText={(id) => latestNote()?.items.find((i) => i.id === id)?.text ?? null}
        onToggle={checklist.toggle}
        onItemText={checklist.text}
        onRemove={checklist.remove}
        onClearChecked={checklist.clearChecked}
        onAdd={checklist.add}
        onInsertAfter={checklist.insertAfter}
        onReplace={(next) => setItems(next)}
        onIndent={checklist.indent}
        onSetReminder={(itemId, value) => notes.setItemReminder(noteId, itemId, value?.at ?? null, value?.repeat ?? null)}
      />
    );
  } else if (kind === "markdown" && preview) {
    content = (
      <div
        className="min-h-36 cursor-text py-3"
        onClick={(event) => {
          // A tap on the rendered text goes back to its source; links and boxes keep theirs.
          const target = event.target as HTMLElement;
          if (!trashed && !target.closest("a, button, input, pre, code") && !window.getSelection()?.toString()) {
            setMarkdownPreview(false);
          }
        }}
      >
        {note.content.trim() === "" ? (
          <p className="text-base text-on-surface-variant italic">Nothing to preview</p>
        ) : (
          <NoteMarkdown source={note.content} variant="editor" onToggleTask={trashed ? undefined : toggleTask} />
        )}
      </div>
    );
  } else {
    content = bodyField(kind === "markdown", "Note");
  }

  const onFiles = (list: FileList | null, failure: string): void => {
    if (list && list.length > 0) {
      void uploadAll(Array.from(list), failure);
    }
  };

  return (
    <div
      className="relative flex min-h-0 flex-1 flex-col"
      onDragOver={(event) => {
        if (trashed || !event.dataTransfer.types.includes("Files")) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        setDropping(true);
      }}
      onDragLeave={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
          setDropping(false);
        }
      }}
      onDrop={(event) => {
        if (trashed || event.dataTransfer.files.length === 0) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        event.nativeEvent.stopImmediatePropagation();
        setDropping(false);
        onFiles(event.dataTransfer.files, "Couldn't upload the dropped files");
      }}
    >
      <TopBar
        noteId={noteId}
        wide={wide}
        onClose={onClose}
        trashed={trashed}
        pinned={note.pinned}
        rewriting={rewriting}
        finding={finding}
        findQuery={findQuery}
        matchCount={findMatchesNow.count}
        matchIndex={matchIndex}
        onFindQuery={(q) => {
          setFindQuery(q);
          setFindIndex(0);
        }}
        onFindStep={findStep}
        onOpenFind={openFind}
        onCloseFind={closeFind}
        preview={kind === "markdown" ? preview : null}
        onTogglePreview={() => setMarkdownPreview(!preview)}
        onTogglePin={() => notes.togglePin(noteId)}
        onArchive={can.canArchive ? archive : null}
        onShare={can.canEdit ? share : null}
        onRestore={restore}
        onDeleteForever={deleteForever}
        onConvert={can.canEdit ? convert : null}
        onRewrite={can.canRewrite ? (task) => void rewrite(task) : null}
      />

      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto overscroll-contain">
        <div className="mx-auto flex w-full max-w-[680px] flex-col px-6 pt-2">
          <textarea
            ref={title}
            rows={1}
            defaultValue={note.title}
            readOnly={readOnly}
            placeholder="Title"
            aria-label="Title"
            autoCapitalize="sentences"
            enterKeyHint="next"
            className="block w-full resize-none overflow-hidden bg-transparent py-2 text-xl leading-7 font-semibold text-on-surface outline-none placeholder:text-on-surface-variant/70"
            onInput={(e) => {
              fitTitle(e.currentTarget);
              onTitleInput(e.currentTarget.value);
            }}
            onPointerDown={() => trashed && showAppSnack(TRASH_HINT)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                // Enter moves on to the body.
                e.preventDefault();
                tapBelow();
              }
            }}
          />
          {/* A new kind, or markdown's source and preview, cross-fade in place. */}
          <StateCrossFade stateKey={kind === "markdown" ? `markdown-${preview}` : kind}>{content}</StateCrossFade>
          <Reveal>
            {note.summarizingLinks ? (
              <div className="pt-3">
                <LinkSummaryIndicator onCancel={() => void notes.cancelLinkSummaries(noteId)} />
              </div>
            ) : null}
          </Reveal>
          <div className="pt-2">
            <AttachmentTiles
              attachments={note.attachments}
              uploading={uploads}
              urlOf={(a) => notes.fileUrl(a)}
              onRemove={trashed ? null : (a) => notes.removeAttachment(noteId, a.id)}
            />
          </div>
          <Reveal>
            {reminder || labels.length > 0 ? (
              <MetaChips
                noteId={noteId}
                reminder={reminder}
                reminderText={reminderText}
                labels={labels}
                readOnly={trashed}
                use24h={use24h}
                onReminder={setReminder}
                onRemoveLabel={(labelId) => notes.toggleLabelOnNote(noteId, labelId)}
              />
            ) : null}
          </Reveal>
          <Reveal>
            {outgoing.length > 0 || incoming.length > 0 ? <NoteLinksSection outgoing={outgoing} incoming={incoming} onOpen={openLinkedNote} /> : null}
          </Reveal>
          <Reveal>
            {urls.length > 0 ? (
              <LinkPreviews
                noteId={noteId}
                urls={urls}
                summarizing={summarizing}
                onSummarize={can.canSummarizeLinks ? (url) => void summarize(url) : null}
                onStopSummarize={stopSummarizing}
              />
            ) : null}
          </Reveal>
          {/* A tap under the note carries on writing at its end, like a sheet of paper. */}
          <div aria-hidden className={cn("min-h-12 flex-1", !readOnly && "cursor-text")} onClick={tapBelow} />
        </div>
      </div>

      <Reveal>
        {linkQuery !== null && !trashed ? (
          <NoteLinkPicker notes={linkCandidates} query={linkQuery} active={linkActive} onPick={insertNoteLink} onHover={setLinkActive} />
        ) : null}
      </Reveal>
      <Reveal>{formatBar ? <MarkdownToolbar onAction={formatMarkdown} /> : null}</Reveal>
      <div className="relative h-0.5 shrink-0 overflow-hidden" aria-hidden={uploads.length === 0}>
        <AnimatePresence initial={false}>
          {uploads.length > 0 ? (
            <motion.span
              key="uploading"
              className="absolute inset-0"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={transitionFor(TRANSITION.fast, reduced)}
            >
              <motion.span
                role="progressbar"
                aria-label="Uploading"
                className="absolute inset-y-0 w-1/3 bg-primary"
                initial={{ x: "-100%" }}
                animate={reduced ? { x: "100%" } : { x: ["-100%", "300%"] }}
                transition={reduced ? { duration: 0 } : { duration: 1.1, ease: "easeInOut", repeat: Infinity }}
              />
            </motion.span>
          ) : null}
        </AnimatePresence>
      </div>
      <div className={cn(!wide && "border-t border-hairline")}>
        <BottomBar
          noteId={noteId}
          trashed={trashed}
          wide={wide}
          editedStamp={`Edited ${editedLabel(note.updatedAt, settingsStore.state)}`}
          color={note.color}
          pattern={note.pattern}
          brightness={brightness}
          palette={palette}
          onColor={(key) => notes.setColor(noteId, key)}
          onPattern={(pattern: NotePattern) => notes.setPattern(noteId, pattern)}
          reminder={reminder}
          use24h={use24h}
          onReminder={setReminder}
          onImage={trashed ? null : () => imageInput.current?.click()}
          onAttach={trashed ? null : () => fileInput.current?.click()}
          onUndo={!trashed && canUndo ? undo : null}
          onRedo={!trashed && canRedo ? redo : null}
        />
      </div>
      <input
        ref={imageInput}
        type="file"
        accept="image/*"
        hidden
        onChange={(e) => {
          onFiles(e.currentTarget.files, "Couldn't upload the image");
          e.currentTarget.value = "";
        }}
      />
      <input
        ref={fileInput}
        type="file"
        multiple
        hidden
        onChange={(e) => {
          onFiles(e.currentTarget.files, "Couldn't upload the file");
          e.currentTarget.value = "";
        }}
      />

      <AnimatePresence>
        {dropping ? (
          <motion.div
            key="drop"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={transitionFor(TRANSITION.fast, reduced)}
            className="pointer-events-none absolute inset-2 z-40 flex items-center justify-center rounded-md border-2 border-dashed border-primary bg-surface/85 text-sm font-medium text-primary"
          >
            Drop files to attach
          </motion.div>
        ) : null}
      </AnimatePresence>

      <ShareDialog noteId={noteId} open={shareOpen} onOpenChange={setShareOpen} />
    </div>
  );
}
