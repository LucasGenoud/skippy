"use client";

import { useState } from "react";
import { LoaderCircle } from "lucide-react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { Button } from "@/components/ui/button";
import { navigate } from "@/lib/router";
import { useAuthController } from "@/lib/store";
import { Field, FormDialog } from "../kit/form-dialog";
import { PasswordInput } from "../kit/password-input";
import { accountErrorText } from "./account-errors";

/** Deletes the account once the current password confirms it. */
export function DeleteAccountDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const auth = useAuthController();
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function remove() {
    if (password === "") {
      setError("Enter your current password");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      // Leave settings before the session goes, so sign-in opens on `/`.
      await auth.deleteAccount(password, () => navigate({ name: "home" }, { replace: true }));
    } catch (e) {
      setError(accountErrorText(e, "Couldn't delete your account"));
      setBusy(false);
    }
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Delete account?"
      width="compact"
      busy={busy}
      onSubmit={() => void remove()}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            Cancel
          </Button>
          <Button variant="destructive" onClick={() => void remove()} disabled={busy}>
            {busy ? <LoaderCircle aria-hidden className="animate-spin" /> : null}
            Delete account
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <p className="text-sm text-on-surface">
          This permanently deletes your account, every workspace you own, and every note inside those workspaces, including notes created by
          other people. Your other notes, attachments, settings, and sessions are also deleted. This cannot be undone.
        </p>
        <Field label="Current password" htmlFor="delete-password">
          <PasswordInput id="delete-password" autoFocus value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <AnimatedFormError message={error} className="pt-0" />
      </div>
    </FormDialog>
  );
}
