"use client";

import { useState, type FormEvent } from "react";
import { Mail, MailCheck } from "lucide-react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { CrossFade, Reveal } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { errorMessage } from "@/lib/api/errors";
import { LoginField } from "./login-field";
import { ButtonSpinner } from "./auth-frame";
import { useOpeningKey } from "./use-opening-key";

// Asks the server to email a reset link (`_ForgotPasswordDialog`). It reports
// the same thing whether or not the address has an account here, because the
// server does: which addresses are registered is exactly what it won't say.

export function ForgotPasswordDialog({
  open,
  onOpenChange,
  initialEmail,
  request,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  initialEmail: string;
  request(email: string): Promise<void>;
}) {
  // Fresh per opening, so each starts from the sign-in form's address.
  const key = useOpeningKey(open);
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <ForgotPasswordBody key={key} initialEmail={initialEmail} request={request} onClose={() => onOpenChange(false)} />
      </DialogContent>
    </Dialog>
  );
}

function ForgotPasswordBody({ initialEmail, request, onClose }: { initialEmail: string; request(email: string): Promise<void>; onClose(): void }) {
  const [email, setEmail] = useState(initialEmail);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** The address the request went out for, once it has. */
  const [sentTo, setSentTo] = useState<string | null>(null);

  const send = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (busy) {
      return;
    }
    const address = email.trim();
    if (address === "") {
      setError("Enter your email");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await request(address);
      setSentTo(address);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={send} className="grid gap-4" noValidate>
      <DialogHeader>
        <DialogTitle>
          <CrossFade stateKey={sentTo === null}>{sentTo === null ? "Reset password" : "Check your email"}</CrossFade>
        </DialogTitle>
        <DialogDescription className={sentTo === null ? undefined : "sr-only"}>
          We&apos;ll email you a link to choose a new password.
        </DialogDescription>
      </DialogHeader>

      <Reveal>
        {sentTo === null ? (
          <div className="pb-0.5">
            <LoginField
              label="Email"
              icon={Mail}
              type="email"
              autoComplete="username"
              autoFocus
              value={email}
              disabled={busy}
              onChange={(e) => {
                setEmail(e.target.value);
                setError(null);
              }}
            />
            <AnimatedFormError message={error} />
          </div>
        ) : null}
      </Reveal>
      <Reveal>
        {sentTo !== null ? (
          <p className="flex items-start gap-3 text-sm text-on-surface-variant" role="status">
            <MailCheck aria-hidden className="mt-0.5 size-5 shrink-0 text-primary" />
            <span>
              If {sentTo} has an account here, a link to choose a new password is on its way. It works once and expires in an hour.
            </span>
          </p>
        ) : null}
      </Reveal>

      <DialogFooter>
        {sentTo === null ? (
          <>
            <Button type="button" variant="ghost" disabled={busy} onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={busy}>
              {busy ? <ButtonSpinner /> : null}
              Send link
            </Button>
          </>
        ) : (
          <Button type="button" autoFocus onClick={onClose}>
            Done
          </Button>
        )}
      </DialogFooter>
    </form>
  );
}
