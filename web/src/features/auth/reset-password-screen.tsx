"use client";

import { useRef, useState, type FormEvent, type KeyboardEvent, type ReactNode } from "react";
import { CircleCheck, KeyRound, Link2Off, LockKeyhole, LogIn } from "lucide-react";
import { motion, useReducedMotion } from "motion/react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { Button } from "@/components/ui/button";
import type { Api } from "@/lib/api/client";
import { ApiError, errorMessage } from "@/lib/api/errors";
import { getPublicApi } from "@/lib/api/public-api";
import { navigate } from "@/lib/router";
import { useAuthController } from "@/lib/store/hooks";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { AuthFrame, ButtonSpinner } from "./auth-frame";
import { AutoHeight } from "./auto-height";
import { validateReset, type ResetField } from "./form-rules";
import { LoginField, RevealPasswordButton, usePasswordVisibility } from "./login-field";

// The page behind an emailed reset link (`screens/reset_password_screen.dart`):
// choose a new password with the token in the URL as the only credential.
// Redeeming the link signs nobody in; it hands back the account's address,
// which the sign-in form is then prefilled with.

/** The server's answer for a link that expired or was already used. */
const HTTP_FORBIDDEN = 403;

type Phase = { readonly name: "form" } | { readonly name: "done"; readonly email: string } | { readonly name: "expired" };

export function ResetPasswordScreen({ token, api }: { token: string; /** For tests; the page's own origin otherwise. */ api?: Api }) {
  const auth = useAuthController();
  const [phase, setPhase] = useState<Phase>({ name: "form" });
  const reduced = useReducedMotion();

  /** Leave for the sign-in form, prefilled with [email] when the reset worked. */
  const toSignIn = (email: string | null): void => {
    auth.setPrefillEmail(email);
    navigate("/", { replace: true });
  };

  return (
    <AuthFrame>
      <AutoHeight>
      <motion.div
        key={phase.name}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={transitionFor(TRANSITION.base, reduced)}
      >
        {phase.name === "form" ? (
          <ResetForm
            token={token}
            api={api ?? getPublicApi()}
            onChanged={(email) => setPhase({ name: "done", email })}
            onExpired={() => setPhase({ name: "expired" })}
            onBack={() => toSignIn(null)}
          />
        ) : phase.name === "done" ? (
          <Outcome
            icon={<CircleCheck aria-hidden className="size-10 text-primary" strokeWidth={1.5} />}
            title="Password updated"
            // Naming the address says which account this was, on a page reached without signing in.
            body={`Sign in as ${phase.email} with your new password. Any devices that were already signed in will need it too.`}
            action={
              <Button size="lg" className="w-full" autoFocus onClick={() => toSignIn(phase.email)}>
                <LogIn />
                Sign in
              </Button>
            }
          />
        ) : (
          <Outcome
            icon={<Link2Off aria-hidden className="size-10 text-on-surface-variant" strokeWidth={1.5} />}
            title="This link has expired"
            body="Reset links work once and expire after an hour. Ask for a new one from the sign-in page."
            action={
              <Button size="lg" variant="outline" className="w-full" autoFocus onClick={() => toSignIn(null)}>
                <LogIn />
                Back to sign in
              </Button>
            }
          />
        )}
      </motion.div>
      </AutoHeight>
    </AuthFrame>
  );
}

function ResetForm({
  token,
  api,
  onChanged,
  onExpired,
  onBack,
}: {
  token: string;
  api: Api;
  onChanged(email: string): void;
  onExpired(): void;
  onBack(): void;
}) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [errors, setErrors] = useState<Partial<Record<ResetField, string>>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const visibility = usePasswordVisibility();
  const passwordRef = useRef<HTMLInputElement>(null);
  const confirmRef = useRef<HTMLInputElement>(null);

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (busy) {
      return;
    }
    // Checked here as well as on the server: a refused attempt would look like it had spent the link.
    const found = validateReset(password, confirm);
    setErrors(found);
    if (found.password) {
      passwordRef.current?.focus();
      return;
    }
    if (found.confirm) {
      confirmRef.current?.focus();
      return;
    }
    setBusy(true);
    setError(null);
    try {
      onChanged(await api.resetPassword(token, password));
    } catch (e) {
      setBusy(false);
      if (e instanceof ApiError && e.statusCode === HTTP_FORBIDDEN) {
        onExpired();
        return;
      }
      setError(errorMessage(e));
    }
  };

  const toConfirm = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key === "Enter" && !event.nativeEvent.isComposing) {
      event.preventDefault();
      confirmRef.current?.focus();
    }
  };

  return (
    <form onSubmit={submit} noValidate aria-label="Choose a new password">
      <h2 className="text-center text-base font-semibold text-on-surface">Choose a new password</h2>
      {/* A hidden username lets password managers file the new password under the account. */}
      <input type="text" name="username" autoComplete="username" hidden readOnly />
      <div className="mt-5 flex flex-col gap-4">
        <LoginField
          ref={passwordRef}
          label="New password"
          icon={LockKeyhole}
          type={visibility.shown ? "text" : "password"}
          autoComplete="new-password"
          autoFocus
          value={password}
          error={errors.password}
          trailing={<RevealPasswordButton shown={visibility.shown} onToggle={visibility.toggle} />}
          onChange={(e) => {
            setPassword(e.target.value);
            setErrors((current) => ({ ...current, password: undefined }));
            setError(null);
          }}
          onKeyDown={toConfirm}
        />
        <LoginField
          ref={confirmRef}
          label="Confirm password"
          icon={LockKeyhole}
          type={visibility.shown ? "text" : "password"}
          autoComplete="new-password"
          value={confirm}
          error={errors.confirm}
          onChange={(e) => {
            setConfirm(e.target.value);
            setErrors((current) => ({ ...current, confirm: undefined }));
          }}
        />
      </div>
      <AnimatedFormError message={error} />
      <Button type="submit" size="lg" className="mt-6 w-full" disabled={busy}>
        {busy ? <ButtonSpinner /> : <KeyRound />}
        Set new password
      </Button>
      <Button type="button" variant="ghost" className="mt-1 w-full" disabled={busy} onClick={onBack}>
        Back to sign in
      </Button>
    </form>
  );
}

function Outcome({ icon, title, body, action }: { icon: ReactNode; title: string; body: string; action: ReactNode }) {
  return (
    <div className="flex flex-col items-center text-center" role="status">
      {icon}
      <h2 className="mt-4 text-base font-semibold text-on-surface">{title}</h2>
      <p className="mt-2 text-sm text-on-surface-variant">{body}</p>
      <div className="mt-6 w-full">{action}</div>
    </div>
  );
}
