"use client";

import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent, type RefObject } from "react";
import { BadgeCheck, LockKeyhole, LogIn, Mail, UserPlus } from "lucide-react";
import { AnimatedFormError } from "@/components/common/form-error-banner";
import { Reveal } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useAuth, useAuthController } from "@/lib/store/hooks";
import { AuthFrame, ButtonSpinner } from "./auth-frame";
import { ForgotPasswordDialog } from "./forgot-password-dialog";
import { firstInvalidField, nextOnEnter, validateLogin, type FieldErrors, type LoginField as Field, type LoginMode } from "./form-rules";
import { LoginField, RevealPasswordButton, usePasswordVisibility } from "./login-field";
import { ServerPicker, type Reachability } from "./server-picker";

// Sign in or create an account (`screens/login_screen.dart`), on whichever
// server is picked underneath. A previously signed-in user never lands here
// while offline: the auth store opens the app from the cached profile.

const HTTP_UNAUTHORIZED = 401;
const HTTP_CONFLICT = 409;

/** What the active server said when asked for its capabilities. */
interface ServerProbe {
  readonly url: string;
  readonly reachable: boolean;
  /** It can email a reset link (depends on the deployment's mail setup). */
  readonly passwordReset: boolean;
}

/** Asks the active server what it offers, once per server switch. */
function useServerProbe(): { reachability: Reachability; passwordReset: boolean } {
  const auth = useAuthController();
  const activeUrl = useAuth((s) => s.activeUrl);
  const [probe, setProbe] = useState<ServerProbe | null>(null);

  useEffect(() => {
    let current = true;
    auth.api.fetchCapabilities().then(
      (caps) => current && setProbe({ url: activeUrl, reachable: true, passwordReset: caps.passwordReset }),
      // Unreachable, or too old to answer: no reset link. Signing in reports the failure itself.
      () => current && setProbe({ url: activeUrl, reachable: false, passwordReset: false }),
    );
    return () => {
      current = false;
    };
  }, [auth, activeUrl]);

  if (probe === null || probe.url !== activeUrl) {
    return { reachability: "checking", passwordReset: false };
  }
  return { reachability: probe.reachable ? "reachable" : "unreachable", passwordReset: probe.passwordReset };
}

export function LoginScreen() {
  const auth = useAuthController();
  const busy = useAuth((s) => s.busy);
  const error = useAuth((s) => s.error);
  const errorStatus = useAuth((s) => s.errorStatus);
  const activeUrl = useAuth((s) => s.activeUrl);
  const savedUrls = useAuth((s) => s.savedUrls);
  const { reachability, passwordReset } = useServerProbe();

  const [mode, setMode] = useState<LoginMode>("signIn");
  // Someone back from the reset page only has the password left to type.
  const [prefill] = useState(() => auth.state.prefillEmail);
  const [name, setName] = useState("");
  const [email, setEmail] = useState(prefill ?? "");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [errors, setErrors] = useState<FieldErrors>({});
  const [forgotOpen, setForgotOpen] = useState(false);
  const visibility = usePasswordVisibility();

  const nameRef = useRef<HTMLInputElement>(null);
  const emailRef = useRef<HTMLInputElement>(null);
  const passwordRef = useRef<HTMLInputElement>(null);
  const confirmRef = useRef<HTMLInputElement>(null);
  const focus = (field: Field): void => {
    const refs: Record<Field, RefObject<HTMLInputElement | null>> = { name: nameRef, email: emailRef, password: passwordRef, confirm: confirmRef };
    refs[field].current?.focus();
  };

  const creating = mode === "create";

  useEffect(() => {
    if (prefill !== null) {
      auth.setPrefillEmail(null);
    }
  }, [auth, prefill]);

  // The first field to fill takes focus, and again whenever the mode changes.
  useEffect(() => {
    if (mode === "create") {
      nameRef.current?.focus();
    } else if (prefill) {
      passwordRef.current?.focus();
    } else {
      emailRef.current?.focus();
    }
  }, [mode, prefill]);

  const switchMode = (next: string): void => {
    if (next !== "signIn" && next !== "create") {
      return;
    }
    setMode(next);
    setErrors({});
    auth.clearError();
  };

  /** A keystroke clears that field's inline error and a rejection's outline. */
  const edited = (field: Field): void => {
    if (errors[field] !== undefined) {
      setErrors((current) => ({ ...current, [field]: undefined }));
    }
    if (auth.state.errorStatus !== null) {
      auth.clearError();
    }
  };

  /** Enter moves to the next field, as the Flutter form does; the last one submits. */
  const onEnter = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key !== "Enter" || event.nativeEvent.isComposing) {
      return;
    }
    const next = nextOnEnter(mode, event.currentTarget.name as Field);
    if (next === "submit") {
      return;
    }
    event.preventDefault();
    focus(next);
  };

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (busy) {
      return;
    }
    const found = validateLogin(mode, { name, email, password, confirm });
    const first = firstInvalidField(found);
    setErrors(found);
    if (first !== null) {
      focus(first);
      return;
    }
    if (creating) {
      await auth.registerAccount(name.trim(), email.trim(), password);
    } else {
      await auth.signIn(email.trim(), password);
    }
  };

  const emailRejected = errorStatus === HTTP_UNAUTHORIZED || errorStatus === HTTP_CONFLICT;
  const passwordRejected = errorStatus === HTTP_UNAUTHORIZED;
  const passwordToggle = <RevealPasswordButton shown={visibility.shown} onToggle={visibility.toggle} />;

  return (
    <AuthFrame
      footer={
        <ServerPicker
          activeUrl={activeUrl}
          savedUrls={savedUrls}
          defaultUrl={auth.defaultUrl()}
          reachability={reachability}
          disabled={busy}
          onSelect={(url) => auth.setActiveUrl(url)}
          onAdd={(url) => auth.addUrl(url)}
          onEdit={(oldUrl, newUrl) => auth.editUrl(oldUrl, newUrl)}
          onRemove={(url) => auth.removeUrl(url)}
        />
      }
    >
      <form onSubmit={submit} noValidate aria-label={creating ? "Create account" : "Sign in"}>
        <Tabs value={mode} onValueChange={switchMode}>
          <TabsList className="w-full">
            <TabsTrigger value="signIn" disabled={busy}>
              Sign in
            </TabsTrigger>
            <TabsTrigger value="create" disabled={busy}>
              Create account
            </TabsTrigger>
          </TabsList>
        </Tabs>

        <div className="mt-5">
          <Reveal>
            {creating ? (
              <div className="pb-4">
                <LoginField
                  ref={nameRef}
                  label="Full name"
                  icon={BadgeCheck}
                  autoComplete="name"
                  autoCapitalize="words"
                  value={name}
                  error={errors.name}
                  onChange={(e) => {
                    setName(e.target.value);
                    edited("name");
                  }}
                  name="name"
                  onKeyDown={onEnter}
                />
              </div>
            ) : null}
          </Reveal>

          <LoginField
            ref={emailRef}
            label="Email"
            icon={Mail}
            type="email"
            inputMode="email"
            // Password managers pair `username` with `current-password`; marking
            // sign-in as plain email makes some treat it as a contact field.
            autoComplete={creating ? "email" : "username"}
            autoCapitalize="none"
            spellCheck={false}
            value={email}
            error={errors.email}
            rejected={emailRejected}
            onChange={(e) => {
              setEmail(e.target.value);
              edited("email");
            }}
            name="email"
                  onKeyDown={onEnter}
          />

          <div className="mt-4">
            <LoginField
              ref={passwordRef}
              label="Password"
              icon={LockKeyhole}
              type={visibility.shown ? "text" : "password"}
              autoComplete={creating ? "new-password" : "current-password"}
              value={password}
              error={errors.password}
              rejected={passwordRejected}
              trailing={passwordToggle}
              onChange={(e) => {
                setPassword(e.target.value);
                edited("password");
              }}
              name="password"
                  onKeyDown={onEnter}
            />
          </div>

          {/* Only while signing in, and only where the server can send the mail. */}
          <Reveal>
            {!creating && passwordReset ? (
              <div className="flex justify-end pt-1">
                <Button type="button" variant="link" size="sm" className="h-7 px-0" disabled={busy} onClick={() => setForgotOpen(true)}>
                  Forgot password?
                </Button>
              </div>
            ) : null}
          </Reveal>

          <Reveal>
            {creating ? (
              <div className="pt-4">
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
                    edited("confirm");
                  }}
                  name="confirm"
                  onKeyDown={onEnter}
                />
              </div>
            ) : null}
          </Reveal>

          <AnimatedFormError message={error} />

          <Button type="submit" size="lg" className="mt-6 w-full" disabled={busy}>
            {busy ? <ButtonSpinner /> : creating ? <UserPlus /> : <LogIn />}
            {creating ? "Create account" : "Sign in"}
          </Button>
        </div>
      </form>

      <ForgotPasswordDialog
        open={forgotOpen}
        onOpenChange={setForgotOpen}
        initialEmail={email.trim()}
        request={(address) => auth.requestPasswordReset(address)}
      />
    </AuthFrame>
  );
}
