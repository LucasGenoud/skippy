"use client";

import { useState } from "react";
import { Bot, Copy, Eye, KeyRound, LoaderCircle, NotebookPen, Plus, RefreshCw } from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { CrossFade } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
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
import { Input } from "@/components/ui/input";
import { claudeCodeCommand, mcpUrl, TOKEN_SCOPES, type ApiToken, type CreatedApiToken, type TokenScope } from "@/lib/models";
import { formatDate, useApi, useSettings } from "@/lib/store";
import { copyText, plural } from "../kit/files";
import { Field, FormDialog, FormSectionLabel } from "../kit/form-dialog";
import { SettingsRow } from "../kit/rows";
import { Segmented } from "../kit/segmented";
import { useDialog } from "../kit/use-dialog";
import { useRemote } from "../kit/use-remote";
import { DenseRow, RevocableList } from "./revocable-list";

export const MAX_TOKEN_NAME_LENGTH = 80;

/** "Read only · last used 3 Jul 2026". */
export function tokenMeta(token: ApiToken, format: (d: Date) => string): string {
  const scope = TOKEN_SCOPES.find((s) => s.id === token.scope)?.label ?? token.scope;
  return `${scope} · ${token.lastUsedAt === null ? "never used" : `last used ${format(token.lastUsedAt)}`}`;
}

/**
 * Personal access tokens, which let an AI assistant reach these notes over
 * MCP: created here, shown once, revocable here.
 */
export function AiAccessSection() {
  const api = useApi();
  const dateFormat = useSettings((s) => s.dateFormat);
  const { remote: load, reload: refresh, update } = useRemote<readonly ApiToken[]>(() => api.fetchApiTokens());
  const creator = useDialog();
  const [created, setCreated] = useState<CreatedApiToken | null>(null);
  const [createdOpen, setCreatedOpen] = useState(false);
  const [revoking, setRevoking] = useState<ApiToken | null>(null);
  const [revokeOpen, setRevokeOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  async function create(name: string, scope: TokenScope) {
    let result: CreatedApiToken;
    setCreating(true);
    try {
      result = await api.createApiToken(name, scope);
    } catch {
      showAppSnack("Couldn't create the token", { kind: "danger" });
      return;
    } finally {
      setCreating(false);
    }
    update((tokens) => [...tokens, result.token]);
    setCreated(result);
    setCreatedOpen(true);
  }

  async function revoke(token: ApiToken) {
    setRevokingId(token.id);
    try {
      await api.deleteApiToken(token.id);
      update((tokens) => tokens.filter((t) => t.id !== token.id));
      showAppSnack("Token revoked", { icon: KeyRound });
    } catch {
      showAppSnack("Couldn't revoke the token", { kind: "danger" });
    } finally {
      setRevokingId(null);
    }
  }

  const tokens = load.state === "ready" ? load.value : [];
  const live = tokens.length;

  return (
    <div>
      <CrossFade stateKey={load.state} className="w-full">
        {load.state === "loading" ? (
          <SettingsRow icon={Bot} title="Assistant access (MCP)" subtitle="Loading…" />
        ) : load.state === "failed" ? (
          <SettingsRow
            icon={Bot}
            tone="destructive"
            title="Assistant access (MCP)"
            subtitle="Can't reach the server right now"
            trailing={<IconButton size="sm" label="Try again" icon={<RefreshCw />} onClick={() => void refresh()} />}
          />
        ) : (
          <SettingsRow
            icon={Bot}
            title="Assistant access (MCP)"
            subtitle={
              live === 0
                ? "Let an AI assistant such as Claude search and read your notes, and add to them if you allow it."
                : `${plural(live, "token")} can reach your notes`
            }
            trailing={
              <Button variant="ghost" size="sm" disabled={creating} onClick={() => creator.show(true)}>
                <CrossFade stateKey={creating}>{creating ? <LoaderCircle aria-hidden className="animate-spin" /> : <Plus aria-hidden />}</CrossFade>
                New token
              </Button>
            }
          />
        )}
      </CrossFade>
      <RevocableList items={tokens} keyOf={(t) => t.id}>
        {(token) => (
          <DenseRow
            icon={token.scope === "write" ? <NotebookPen aria-hidden /> : <Eye aria-hidden />}
            title={token.name}
            meta={tokenMeta(token, (d) => formatDate(d, dateFormat))}
            state={revokingId === token.id ? "pending" : "idle"}
            actions={
              <IconButton
                size="sm"
                label="Revoke token"
                icon={<KeyRound />}
                onClick={() => {
                  setRevoking(token);
                  setRevokeOpen(true);
                }}
              />
            }
          />
        )}
      </RevocableList>
      <NewTokenDialog key={creator.key} open={creator.open} onOpenChange={creator.onOpenChange} onCreate={(name, scope) => void create(name, scope)} />
      {created ? <TokenCreatedDialog created={created} baseUrl={api.baseUrl} open={createdOpen} onOpenChange={setCreatedOpen} /> : null}
      <AlertDialog open={revokeOpen} onOpenChange={setRevokeOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Revoke &ldquo;{revoking?.name}&rdquo;?</AlertDialogTitle>
            <AlertDialogDescription>Any assistant using this token loses access to your notes immediately.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => revoking && void revoke(revoking)}>Revoke</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/** Names a token and picks what it may do. */
function NewTokenDialog({ open, onOpenChange, onCreate }: { open: boolean; onOpenChange: (open: boolean) => void; onCreate: (name: string, scope: TokenScope) => void }) {
  const [name, setName] = useState("");
  const [scope, setScope] = useState<TokenScope>("read");
  const ready = name.trim() !== "";

  function submit() {
    if (!ready) {
      return;
    }
    onOpenChange(false);
    onCreate(name.trim(), scope);
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="New assistant token"
      onSubmit={submit}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={submit} disabled={!ready}>
            Create
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Field label="Name" htmlFor="token-name" helper={`${name.length}/${MAX_TOKEN_NAME_LENGTH}`}>
          <Input id="token-name" autoFocus maxLength={MAX_TOKEN_NAME_LENGTH} placeholder="Claude on my laptop" value={name} onChange={(e) => setName(e.target.value)} />
        </Field>
        <div className="flex flex-col gap-2">
          <FormSectionLabel>What it may do</FormSectionLabel>
          <Segmented label="What it may do" value={scope} onChange={setScope} options={TOKEN_SCOPES.map((s) => ({ value: s.id, label: s.label }))} className="w-full" />
          <p className="text-xs text-on-surface-variant">
            {scope === "read"
              ? "Search, list and read notes in every workspace you belong to."
              : "Also create notes and add to existing ones. It cannot delete, move or share anything."}
          </p>
        </div>
      </div>
    </FormDialog>
  );
}

/** The secret, shown this once, with what to paste where. Only Done closes it. */
function TokenCreatedDialog({ created, baseUrl, open, onOpenChange }: { created: CreatedApiToken; baseUrl: string; open: boolean; onOpenChange: (open: boolean) => void }) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent showCloseButton={false} onInteractOutside={(e) => e.preventDefault()} onEscapeKeyDown={(e) => e.preventDefault()} className="sm:max-w-[520px]">
        <DialogHeader>
          <DialogTitle>Token created</DialogTitle>
          <DialogDescription className="text-error">Copy the token now. It is not shown again; if it is lost, revoke it and create another.</DialogDescription>
        </DialogHeader>
        <div className="flex min-w-0 flex-col gap-3">
          <CopyField label="Token" value={created.secret} />
          <CopyField label="Server URL" value={mcpUrl(baseUrl)} />
          <CopyField label="Claude Code" value={claudeCodeCommand(baseUrl, created.secret)} />
          <p className="text-xs text-on-surface-variant">
            Other MCP clients: add a Streamable HTTP server at the URL above, with the header Authorization: Bearer followed by the token.
          </p>
        </div>
        <DialogFooter>
          <Button onClick={() => onOpenChange(false)}>Done</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function CopyField({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-1">
      <FormSectionLabel>{label}</FormSectionLabel>
      <div className="flex items-start gap-2 rounded-md bg-code-fill px-3 py-2">
        <code className="min-w-0 flex-1 font-mono text-xs break-all select-all">{value}</code>
        <IconButton
          size="sm"
          label={`Copy ${label.toLowerCase()}`}
          icon={<Copy />}
          className="-my-1 -mr-2"
          onClick={() => {
            void copyText(value).then((ok) => ok && showAppSnack(`${label} copied`, { icon: Copy }));
          }}
        />
      </div>
    </div>
  );
}
