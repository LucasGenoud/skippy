"use client";

import { useState, type FormEvent } from "react";
import { ChevronRight, Link2, LogOut, Send, UserPlus, X } from "lucide-react";

import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Separator } from "@/components/ui/separator";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { CrossFade } from "@/components/common/reveal";
import { IconButton } from "@/components/common/icon-button";
import { ApiError } from "@/lib/api/errors";
import { isNoteOwnedBy, type UserRef } from "@/lib/models/note";
import { useNote, useNotesController, useSession } from "@/lib/store";
import { PublicLinkDialog } from "./public-link-dialog";

// Collaborators of one note (`share_dialog.dart`). The owner adds and removes
// people by email; a collaborator sees the roster and may leave, which closes
// the note for them.

const OFFLINE_MESSAGE = "Can't reach the server right now";

function initial(name: string): string {
  return (name.trim()[0] ?? "?").toUpperCase();
}

function PersonRow({ name, subtitle, action }: { name: string; subtitle?: string; action?: React.ReactNode }) {
  return (
    <li className="flex min-h-11 items-center gap-3 rounded-md px-1">
      <Avatar className="size-8">
        <AvatarFallback className="text-xs">{initial(name)}</AvatarFallback>
      </Avatar>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm text-on-surface">{name}</span>
        {subtitle ? <span className="block text-xs text-on-surface-variant">{subtitle}</span> : null}
      </span>
      {action}
    </li>
  );
}

export function ShareDialog({ noteId, open, onOpenChange }: { noteId: string; open: boolean; onOpenChange(open: boolean): void }) {
  const [linkOpen, setLinkOpen] = useState(false);
  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent>
          {open ? <ShareBody noteId={noteId} onClose={() => onOpenChange(false)} onPublicLink={() => setLinkOpen(true)} /> : null}
        </DialogContent>
      </Dialog>
      <PublicLinkDialog noteId={noteId} open={linkOpen} onOpenChange={setLinkOpen} />
    </>
  );
}

function ShareBody({ noteId, onClose, onPublicLink }: { noteId: string; onClose(): void; onPublicLink(): void }) {
  const store = useNotesController();
  const { userId: me } = useSession();
  const note = useNote(noteId);
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!note) {
    return (
      <>
        <DialogHeader>
          <DialogTitle>Collaborators</DialogTitle>
          <DialogDescription>Note is gone.</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
        </DialogFooter>
      </>
    );
  }
  const isOwner = isNoteOwnedBy(note, me);

  const add = async (event?: FormEvent): Promise<void> => {
    event?.preventDefault();
    const address = email.trim();
    if (!address || busy) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await store.addCollaborator(noteId, address);
      setEmail("");
    } catch (e) {
      setError(e instanceof ApiError ? e.serverMessage : OFFLINE_MESSAGE);
    } finally {
      setBusy(false);
    }
  };

  const remove = (person: UserRef): void => {
    const leaving = person.id === me;
    store.removeCollaborator(noteId, person.id);
    if (leaving) {
      onClose();
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Collaborators</DialogTitle>
        <DialogDescription className="sr-only">People who can edit this note</DialogDescription>
      </DialogHeader>
      <ul className="-mx-1 flex flex-col gap-1">
        <PersonRow name={note.owner?.name || "You"} subtitle="Owner" />
        {note.collaborators.map((person) => {
          const self = person.id === me;
          const canAct = isOwner || self;
          return (
            <PersonRow
              key={person.id}
              name={self ? `${person.name} (you)` : person.name}
              action={
                canAct ? (
                  <IconButton
                    size="sm"
                    label={self ? "Leave note" : "Remove"}
                    icon={self ? <LogOut /> : <X />}
                    onClick={() => remove(person)}
                  />
                ) : null
              }
            />
          );
        })}
      </ul>
      {isOwner ? (
        <>
          <form className="flex items-center gap-2" onSubmit={(e) => void add(e)}>
            <div className="relative flex-1">
              <UserPlus aria-hidden className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-on-surface-variant" />
              <Input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="Add people by email"
                aria-label="Add people by email"
                className="pl-9"
                disabled={busy}
              />
            </div>
            <CrossFade stateKey={busy}>
              <IconButton type="submit" label="Share" icon={busy ? <Spinner /> : <Send />} disabled={busy || email.trim() === ""} />
            </CrossFade>
          </form>
          <AnimatedFormError message={error} className="pt-0" />
          <Separator />
          <button
            type="button"
            onClick={onPublicLink}
            className="-mx-1 flex min-h-12 items-center gap-3 rounded-md px-2 text-left transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
          >
            <Link2 aria-hidden className="size-5 text-on-surface-variant" />
            <span className="min-w-0 flex-1">
              <span className="block text-sm text-on-surface">Public link</span>
              <span className="block text-xs text-on-surface-variant">Read-only, for people without an account</span>
            </span>
            <ChevronRight aria-hidden className="size-4 text-on-surface-variant" />
          </button>
        </>
      ) : (
        <p className="text-xs text-on-surface-variant">Everyone here can edit this note.</p>
      )}
      <DialogFooter>
        <Button variant="ghost" onClick={onClose}>
          Done
        </Button>
      </DialogFooter>
    </>
  );
}

function Spinner() {
  return <span aria-hidden className="size-4 animate-spin rounded-full border-2 border-on-surface-variant/30 border-t-primary" />;
}
