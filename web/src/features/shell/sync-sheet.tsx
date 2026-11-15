"use client";

import { CircleAlert, CloudCheck, CloudOff, Copy, LoaderCircle, RefreshCw } from "lucide-react";
import { showAppSnack } from "@/components/common/snack";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import { isConflictIssue, syncIssueCopyText, syncIssueLabel } from "@/lib/state/sync-issue";
import { useNotesController, useNotesSelector, useSyncIssues } from "@/lib/store";
import { AdaptiveSurface } from "./adaptive-surface";
import { syncSummary } from "./sync-rules";

/**
 * What has and has not reached the server (`_showSyncSheet`): the queue, an
 * offline-copy failure, and each refused write with a way to copy the text
 * out, retry, load the server's version, or let it go.
 */
export function SyncSheet({ open, onOpenChange }: { open: boolean; onOpenChange(open: boolean): void }) {
  const notes = useNotesController();
  const issues = useSyncIssues();
  const status = useNotesSelector((s) => s.syncStatus);
  const pending = useNotesSelector((s) => s.pendingChanges);
  const cacheFailure = useNotesSelector((s) => s.cacheFailure);
  const refreshing = useNotesSelector((s) => s.refreshing);
  const summary = syncSummary({ status, pending, issues: issues.length, cacheFailure: cacheFailure !== null });
  const Icon = summary.tone === "error" ? CircleAlert : status === "offline" ? CloudOff : CloudCheck;

  const copy = async (text: string): Promise<void> => {
    try {
      await navigator.clipboard.writeText(text);
      showAppSnack("Edit copied", { icon: Copy });
    } catch {
      showAppSnack("Couldn't copy the edit", { kind: "danger", icon: CircleAlert });
    }
  };

  return (
    <AdaptiveSurface
      open={open}
      onOpenChange={onOpenChange}
      title="Sync status"
      footer={
        <Button variant="outline" size="sm" disabled={refreshing} onClick={() => void notes.refresh()}>
          {refreshing ? <LoaderCircle className="animate-spin" /> : <RefreshCw />}
          Refresh now
        </Button>
      }
    >
      <div className="flex flex-col gap-3 pb-1">
        <p className="flex items-center gap-2 text-sm text-on-surface">
          <Icon aria-hidden className={summary.tone === "error" ? "size-4 text-error" : "size-4 text-on-surface-variant"} />
          {summary.text}
        </p>
        {cacheFailure !== null ? (
          <div className="flex flex-col items-start gap-2 rounded-md bg-error-container p-3 text-[13px] leading-5 text-on-error-container">
            This device could not save its offline copy. Keep the app open until changes reach the server.
            <Button variant="outline" size="sm" onClick={() => notes.retryCacheWrite()}>
              Retry offline save
            </Button>
          </div>
        ) : null}
        {issues.map((issue, i) => {
          const copyText = syncIssueCopyText(issue);
          const conflict = isConflictIssue(issue);
          const label = syncIssueLabel(issue);
          return (
            <div key={i} className="flex flex-col gap-2">
              <Separator className="bg-hairline" />
              <div>
                <p className="text-sm font-medium text-on-surface">{label === "" ? "Untitled note" : label}</p>
                <p className="text-xs text-on-surface-variant">
                  {conflict ? "This note changed elsewhere. Copy your edit before loading the server version." : issue.message}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                {copyText ? (
                  <Button variant="ghost" size="sm" onClick={() => void copy(copyText)}>
                    <Copy />
                    Copy edit
                  </Button>
                ) : null}
                {conflict ? (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => {
                      void notes.refresh().then(() => onOpenChange(false));
                    }}
                  >
                    Load server version
                  </Button>
                ) : (
                  <Button variant="ghost" size="sm" onClick={() => notes.retrySyncIssue(issue)}>
                    Retry
                  </Button>
                )}
                <Button variant="ghost" size="sm" onClick={() => notes.dismissSyncIssue(issue)}>
                  Dismiss
                </Button>
              </div>
            </div>
          );
        })}
      </div>
    </AdaptiveSurface>
  );
}
