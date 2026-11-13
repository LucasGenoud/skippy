"use client";

import { useEffect, useMemo, useState } from "react";
import { Copy, Infinity as Forever, Link2, Link2Off, Clock } from "lucide-react";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { IconButton } from "@/components/common/icon-button";
import { showAppSnack } from "@/components/common/snack";
import { ApiError } from "@/lib/api/errors";
import type { ShareLinkRequest } from "@/lib/api/client";
import { publicShareUrl, type ShareLink } from "@/lib/models/misc";
import { useApi, useNote, useSettings, formatDate } from "@/lib/store";

// Publish, copy or revoke the public, read-only link of one note or one view
// (`public_link_dialog.dart`). Opening it publishes nothing: the link exists
// only once asked for, so a stray tap never puts a page on the internet.

const OFFLINE_MESSAGE = "Can't reach the server right now";
const NOTE_SCOPE =
  "Anyone with the link can read this note and open its images. They cannot edit it, and they never see who else it is shared with.";
const MS_PER_DAY = 86_400_000;

const LIFETIMES = [
  { id: "forever", label: "Until I revoke it", days: null },
  { id: "day", label: "1 day", days: 1 },
  { id: "week", label: "7 days", days: 7 },
  { id: "month", label: "30 days", days: 30 },
] as const;
type Lifetime = (typeof LIFETIMES)[number]["id"];

/** What a link publishes (`PublicLinkTarget`): the request, its name and what a reader can see. */
export interface PublicLinkTarget {
  readonly request: Omit<ShareLinkRequest, "expiresAt">;
  readonly title: string;
  readonly scope: string;
}

/** The existing link for [target], matched on every field that names it. */
function matches(link: ShareLink, { request }: PublicLinkTarget): boolean {
  return (
    link.target === request.target &&
    link.noteId === (request.noteId ?? null) &&
    link.workspaceId === (request.workspaceId ?? null) &&
    link.collectionId === (request.collectionId ?? null) &&
    link.labelId === (request.labelId ?? null)
  );
}

export function PublicLinkDialog({ noteId, open, onOpenChange }: { noteId: string; open: boolean; onOpenChange(open: boolean): void }) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>{open ? <NoteLinkBody noteId={noteId} onClose={() => onOpenChange(false)} /> : null}</DialogContent>
    </Dialog>
  );
}

/** The same dialog for a whole view: a collection's notes, its board, or a label. */
export function ViewLinkDialog({ target, open, onOpenChange }: { target: PublicLinkTarget; open: boolean; onOpenChange(open: boolean): void }) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>{open ? <LinkBody target={target} onClose={() => onOpenChange(false)} /> : null}</DialogContent>
    </Dialog>
  );
}

function NoteLinkBody({ noteId, onClose }: { noteId: string; onClose(): void }) {
  const title = useNote(noteId)?.title.trim() || "this note";
  const target = useMemo<PublicLinkTarget>(() => ({ request: { target: "note", noteId }, title, scope: NOTE_SCOPE }), [noteId, title]);
  return <LinkBody target={target} onClose={onClose} />;
}

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

function LinkBody({ target, onClose }: { target: PublicLinkTarget; onClose(): void }) {
  const api = useApi();
  const dateFormat = useSettings((s) => s.dateFormat);
  const [link, setLink] = useState<ShareLink | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lifetime, setLifetime] = useState<Lifetime>("forever");
  const [confirming, setConfirming] = useState(false);
  const { title } = target;

  useEffect(() => {
    let live = true;
    api.fetchShareLinks().then(
      (links) => {
        if (live) {
          setLink(links.find((l) => matches(l, target)) ?? null);
          setLoading(false);
        }
      },
      () => {
        if (live) {
          setLoading(false);
          setError(OFFLINE_MESSAGE);
        }
      },
    );
    return () => {
      live = false;
    };
  }, [api, target]);

  const url = link ? publicShareUrl(api.baseUrl, link) : "";

  const create = async (): Promise<void> => {
    if (busy) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const days = LIFETIMES.find((l) => l.id === lifetime)?.days ?? null;
      const created = await api.createShareLink({
        ...target.request,
        expiresAt: days === null ? null : new Date(Date.now() + days * MS_PER_DAY),
      });
      setLink(created);
      setBusy(false);
      await copyText(publicShareUrl(api.baseUrl, created));
      showAppSnack("Public link created and copied", { icon: Link2, kind: "success" });
    } catch (e) {
      setError(e instanceof ApiError ? e.serverMessage : OFFLINE_MESSAGE);
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (): Promise<void> => {
    if (!link || busy) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.deleteShareLink(link.token);
      setLink(null);
      showAppSnack("Public link revoked", { icon: Link2Off, kind: "danger" });
    } catch {
      setError(OFFLINE_MESSAGE);
    } finally {
      setBusy(false);
    }
  };

  const copy = async (): Promise<void> => {
    if (await copyText(url)) {
      showAppSnack("Link copied", { icon: Copy });
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Public link</DialogTitle>
        <DialogDescription>{target.scope}</DialogDescription>
      </DialogHeader>
      <div className="min-h-[68px]">
        {loading ? (
          <div className="flex flex-col gap-2">
            <Skeleton className="h-9 w-full" />
            <Skeleton className="h-4 w-1/2" />
          </div>
        ) : link ? (
          <div className="flex flex-col gap-2.5 animate-in fade-in-0 duration-150">
            <div className="flex items-center gap-1 rounded-md border border-outline-variant bg-surface-container-highest py-1 pr-1 pl-3">
              <input
                readOnly
                value={url}
                aria-label="Public link"
                onFocus={(e) => e.currentTarget.select()}
                className="min-w-0 flex-1 bg-transparent text-xs text-on-surface outline-none"
              />
              <IconButton size="sm" label="Copy link" icon={<Copy />} onClick={() => void copy()} />
            </div>
            <p className="flex items-center gap-2 text-xs text-on-surface-variant">
              {link.expiresAt === null ? <Forever aria-hidden className="size-4" /> : <Clock aria-hidden className="size-4" />}
              {link.expiresAt === null ? "Works until you revoke it" : `Stops working on ${formatDate(link.expiresAt, dateFormat)}`}
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-3 animate-in fade-in-0 duration-150">
            <p className="text-sm text-on-surface">Sharing {title}</p>
            <div className="flex items-center justify-between gap-3">
              <Label htmlFor="public-link-lifetime">Link lasts</Label>
              <Select value={lifetime} onValueChange={(v) => setLifetime(v as Lifetime)}>
                <SelectTrigger id="public-link-lifetime" size="sm" className="min-w-40">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {LIFETIMES.map((option) => (
                    <SelectItem key={option.id} value={option.id}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
        )}
      </div>
      <AnimatedFormError message={error} className="pt-0" />
      <DialogFooter>
        {link ? (
          <Button variant="ghost" className="text-error hover:text-error sm:mr-auto" disabled={busy} onClick={() => setConfirming(true)}>
            Revoke
          </Button>
        ) : null}
        <Button variant="ghost" onClick={onClose}>
          Done
        </Button>
        {link ? (
          <Button onClick={() => void copy()}>
            <Copy />
            Copy
          </Button>
        ) : loading ? null : (
          <Button disabled={busy} onClick={() => void create()}>
            <Link2 />
            Create link
          </Button>
        )}
      </DialogFooter>
      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Revoke this link?</AlertDialogTitle>
            <AlertDialogDescription>
              The page stops working immediately for everyone holding it. Nothing else about the notes changes.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" onClick={() => void revoke()}>
              Revoke
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
