"use client";

import { useState } from "react";
import { Copy, Globe, GlobeLock, LayoutGrid, LinkIcon, RefreshCw, StickyNote, Tag, Unlink, Columns3 } from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { CrossFade } from "@/components/common/reveal";
import { showAppSnack } from "@/components/common/snack";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { publicShareUrl, shareTargetNoun, type ShareLink, type ShareTarget } from "@/lib/models";
import { formatDate, useApi, useSettings } from "@/lib/store";
import { copyText } from "../kit/files";
import { SettingsRow } from "../kit/rows";
import { useRemote } from "../kit/use-remote";
import { DenseRow, RevocableList } from "./revocable-list";

const TARGET_ICONS: Record<ShareTarget, typeof StickyNote> = { note: StickyNote, notes: LayoutGrid, board: Columns3, label: Tag };

/**
 * Every public link this account has published, to copy or take down. Links
 * are made from what they point at; what is on the internet is an account
 * question, so it is answered here.
 */
export function PublicLinksSection() {
  const api = useApi();
  const dateFormat = useSettings((s) => s.dateFormat);
  const { remote: load, reload: refresh, update } = useRemote<readonly ShareLink[]>(() => api.fetchShareLinks());
  const [confirming, setConfirming] = useState<ShareLink | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);

  async function revoke(link: ShareLink) {
    try {
      await api.deleteShareLink(link.token);
      update((links) => links.filter((x) => x.token !== link.token));
      showAppSnack("Public link revoked", { icon: Unlink, kind: "danger" });
    } catch {
      showAppSnack("Couldn't revoke the link", { kind: "danger" });
    }
  }

  async function copy(link: ShareLink) {
    if (await copyText(publicShareUrl(api.baseUrl, link))) {
      showAppSnack("Link copied", { icon: Copy });
    }
  }

  const refreshButton = <IconButton size="sm" label={load.state === "failed" ? "Try again" : "Refresh"} icon={<RefreshCw />} onClick={() => void refresh()} />;
  const links = load.state === "ready" ? load.value : [];
  const stateKey = load.state === "ready" ? (links.length === 0 ? "empty" : "list") : load.state;

  return (
    <div>
      <CrossFade stateKey={stateKey} className="w-full">
        {load.state === "loading" ? (
          <SettingsRow icon={Globe} title="Public links" subtitle="Loading…" />
        ) : load.state === "failed" ? (
          <SettingsRow icon={GlobeLock} title="Public links" subtitle="Can't reach the server right now" trailing={refreshButton} />
        ) : links.length === 0 ? (
          <SettingsRow icon={Globe} title="Public links" subtitle="Nothing is shared publicly. Share a note or a view to create one." trailing={refreshButton} />
        ) : (
          <SettingsRow
            icon={Globe}
            title="Public links"
            subtitle={`${links.length} ${links.length === 1 ? "link is" : "links are"} readable by anyone holding the URL`}
            trailing={refreshButton}
          />
        )}
      </CrossFade>
      <RevocableList items={links} keyOf={(l) => l.token}>
        {(link) => {
          const Icon = TARGET_ICONS[link.target] ?? LinkIcon;
          const meta =
            link.expiresAt === null
              ? `${shareTargetNoun(link.target)} · shared ${formatDate(link.createdAt, dateFormat)}`
              : `${shareTargetNoun(link.target)} · expires ${formatDate(link.expiresAt, dateFormat)}`;
          return (
            <DenseRow
              icon={<Icon aria-hidden />}
              title={link.title}
              meta={meta}
              actions={
                <>
                  <IconButton size="sm" label="Copy link" icon={<Copy />} onClick={() => void copy(link)} />
                  <IconButton
                    size="sm"
                    label="Revoke link"
                    icon={<Unlink />}
                    onClick={() => {
                      setConfirming(link);
                      setConfirmOpen(true);
                    }}
                  />
                </>
              }
            />
          );
        }}
      </RevocableList>
      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Revoke the link to &ldquo;{confirming?.title}&rdquo;?</AlertDialogTitle>
            <AlertDialogDescription>The page stops working immediately for everyone holding it. Nothing else about the notes changes.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => confirming && void revoke(confirming)}>Revoke</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
