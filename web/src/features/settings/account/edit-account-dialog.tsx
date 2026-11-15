"use client";

import { useState } from "react";
import { LoaderCircle } from "lucide-react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAuth, useAuthController } from "@/lib/store";
import { Field, FormDialog } from "../kit/form-dialog";
import { PasswordInput } from "../kit/password-input";
import { accountErrorText, validateAccountForm, type AccountField } from "./account-errors";

const TITLES: Record<AccountField, string> = { name: "Change name", email: "Change email", password: "Change password" };
const VALUE_LABELS: Record<AccountField, string> = { name: "Full name", email: "New email", password: "New password" };

/** Edits one account field; email and password need the current password. */
export function EditAccountDialog({ field, open, onOpenChange }: { field: AccountField; open: boolean; onOpenChange: (open: boolean) => void }) {
  const auth = useAuthController();
  const user = useAuth((s) => s.user);
  const [value, setValue] = useState(field === "name" ? (user?.name ?? "") : field === "email" ? (user?.email ?? "") : "");
  const [current, setCurrent] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const needsCurrent = field !== "name";

  async function save() {
    const invalid = validateAccountForm(field, value, current, confirm);
    if (invalid) {
      setError(invalid);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const trimmed = value.trim();
      if (field === "name") {
        await auth.updateAccount({ name: trimmed });
      } else if (field === "email") {
        await auth.updateAccount({ email: trimmed, currentPassword: current });
      } else {
        await auth.updateAccount({ currentPassword: current, newPassword: trimmed });
      }
      onOpenChange(false);
    } catch (e) {
      setError(accountErrorText(e, "Couldn't update your account"));
    } finally {
      setBusy(false);
    }
  }

  return (
    <FormDialog
      open={open}
      onOpenChange={onOpenChange}
      title={TITLES[field]}
      width="compact"
      busy={busy}
      onSubmit={() => void save()}
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void save()} disabled={busy}>
            {busy ? <LoaderCircle aria-hidden className="animate-spin" /> : null}
            Save
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {needsCurrent ? (
          <Field label="Current password" htmlFor="account-current">
            <PasswordInput id="account-current" autoFocus value={current} onChange={(e) => setCurrent(e.target.value)} />
          </Field>
        ) : null}
        <Field label={VALUE_LABELS[field]} htmlFor="account-value">
          {field === "password" ? (
            <PasswordInput id="account-value" autoComplete="new-password" value={value} onChange={(e) => setValue(e.target.value)} />
          ) : (
            <Input
              id="account-value"
              autoFocus={!needsCurrent}
              type={field === "email" ? "email" : "text"}
              autoComplete={field === "email" ? "email" : "name"}
              autoCapitalize={field === "name" ? "words" : "none"}
              value={value}
              onChange={(e) => setValue(e.target.value)}
            />
          )}
        </Field>
        {field === "password" ? (
          <Field label="Confirm new password" htmlFor="account-confirm">
            <PasswordInput id="account-confirm" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
          </Field>
        ) : null}
        <AnimatedFormError message={error} className="pt-0" />
      </div>
    </FormDialog>
  );
}
