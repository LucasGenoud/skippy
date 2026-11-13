"use client";

import { useState } from "react";
import { LoaderCircle, LogOut, Send, UserPlus, X } from "lucide-react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { IconButton } from "@/components/common/icon-button";
import { Input } from "@/components/ui/input";
import { ApiError } from "@/lib/api/errors";
import type { Workspace } from "@/lib/models";
import { closeTo } from "@/lib/router";
import { useAuth, useNotesController } from "@/lib/store";
import { cn } from "@/lib/utils";
import { Hint } from "@/features/settings/kit/rows";
import { RevocableList } from "@/features/settings/sharing/revocable-list";

/** A workspace's or person's first character, for the avatar that stands in for them. */
export function initialOf(name: string): string {
  const first = Array.from(name.trim())[0];
  return first ? first.toUpperCase() : "?";
}

/** One person on the roster; [initialFrom] is whose initial the avatar shows when [name] is a label like "You". */
function Person({ name, initialFrom = name, role, tone, action }: { name: string; initialFrom?: string; role: string; tone: "owner" | "member"; action?: React.ReactNode }) {
  return (
    <div className="flex min-h-14 items-center gap-4 rounded-md px-3 py-2">
      <span
        aria-hidden
        className={cn(
          "inline-flex size-8 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
          tone === "owner" ? "bg-primary-container text-on-primary-container" : "bg-secondary-container text-on-secondary-container",
        )}
      >
        {initialOf(initialFrom)}
      </span>
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-sm text-on-surface">{name}</span>
        <span className="text-xs text-on-surface-variant">{role}</span>
      </span>
      {action}
    </div>
  );
}

/** The owner, the members, and (for the owner) an invite field. */
export function PeopleSection({ workspace, isOwner }: { workspace: Workspace; isOwner: boolean }) {
  const notes = useNotesController();
  const me = notes.currentUserId;
  const myName = useAuth((s) => s.user?.name ?? "");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function invite() {
    const trimmed = email.trim();
    if (!trimmed || busy) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await notes.addWorkspaceMember(workspace.id, trimmed);
      setEmail("");
    } catch (e) {
      setError(e instanceof ApiError ? e.serverMessage : "Can't reach the server right now");
    } finally {
      setBusy(false);
    }
  }

  function remove(userId: string) {
    notes.removeWorkspaceMember(workspace.id, userId);
    // Leaving takes the workspace away, and this page with it.
    if (userId === me) {
      closeTo({ name: "home" });
    }
  }

  return (
    <>
      <Person name={isOwner ? "You" : workspace.owner?.name || "Owner"} initialFrom={isOwner ? myName : undefined} role="Owner" tone="owner" />
      <RevocableList items={workspace.members} keyOf={(m) => m.id}>
        {(member) => {
          const self = member.id === me;
          return (
            <Person
              name={self ? `${member.name} (you)` : member.name}
              role="Member"
              tone="member"
              action={
                isOwner || self ? (
                  <IconButton size="sm" label={self ? "Leave workspace" : `Remove ${member.name}`} icon={self ? <LogOut /> : <X />} onClick={() => remove(member.id)} />
                ) : undefined
              }
            />
          );
        }}
      </RevocableList>
      {isOwner ? (
        <div className="px-3 pt-2">
          <form
            className="flex items-center gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              void invite();
            }}
          >
            <div className="relative flex-1">
              <UserPlus aria-hidden className="pointer-events-none absolute top-2.5 left-3 size-4 text-on-surface-variant" />
              <Input
                type="email"
                aria-label="Invite people by email"
                placeholder="Invite people by email"
                className="pl-9"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>
            {busy ? (
              <span className="inline-flex size-9 items-center justify-center">
                <LoaderCircle aria-label="Inviting" className="size-5 animate-spin text-on-surface-variant" />
              </span>
            ) : (
              <IconButton type="submit" label="Invite" icon={<Send />} />
            )}
          </form>
          <AnimatedFormError message={error} className="pt-2" />
        </div>
      ) : null}
      <Hint className="pt-3">
        {isOwner
          ? "Everyone here can see and edit this workspace's notes and labels."
          : "Everyone here can see and edit this workspace's notes and labels. Only the owner can invite people."}
      </Hint>
    </>
  );
}
