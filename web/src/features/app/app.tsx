"use client";

import { useState, useSyncExternalStore, type ReactNode } from "react";
import { motion, MotionConfig, useReducedMotion } from "motion/react";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useRoute } from "@/lib/router";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { AuthProvider, useAuth } from "@/lib/store/hooks";
import { LoginScreen, ResetPasswordScreen } from "@/features/auth";
import { PublicShareScreen } from "@/features/public";
import { getRuntime, type Runtime } from "./runtime";
import { SignedInApp } from "./signed-in-app";
import { Splash } from "./splash";
import { ThemeSync } from "./theme-sync";

// The app root. Public routes render without auth; everything else goes
// through the auth gate, which mounts the signed-in user's stores.

type GateState = "restoring" | "signedOut" | "signedIn";

/**
 * Fades in whatever the gate shows next (the root `AnimatedSwitcher` over
 * the auth status), so signing in or out never cuts from one screen to the
 * next. What the app opens on just appears. The old screen is not kept for
 * an exit: a signed-out session's stores are already gone.
 */
function GateFade({ state, children }: { state: GateState; children: ReactNode }) {
  const reduced = useReducedMotion();
  const [shown, setShown] = useState({ state, switched: false });
  if (shown.state !== state) {
    setShown({ state, switched: true });
  }
  return (
    <motion.div
      key={state}
      initial={shown.switched ? { opacity: 0 } : false}
      animate={{ opacity: 1 }}
      transition={transitionFor(TRANSITION.slow, reduced)}
    >
      {children}
    </motion.div>
  );
}

function AuthGate({ runtime }: { runtime: Runtime }) {
  const status = useAuth((s) => s.status);
  const session = useSyncExternalStore(runtime.sessions.subscribe, runtime.sessions.get, runtime.sessions.get);
  if (status === "restoring") {
    return (
      <GateFade state="restoring">
        <Splash />
      </GateFade>
    );
  }
  if (status === "signedOut" || session === null) {
    return (
      <GateFade state="signedOut">
        <ThemeSync mode="system" />
        <LoginScreen />
      </GateFade>
    );
  }
  return (
    <GateFade state="signedIn">
      <SignedInApp key={session.userId} session={session} />
    </GateFade>
  );
}

function Routes({ runtime }: { runtime: Runtime }) {
  const route = useRoute();
  if (route.name === "publicShare") {
    return (
      <>
        <ThemeSync mode="system" />
        <PublicShareScreen token={route.token} />
      </>
    );
  }
  if (route.name === "resetPassword") {
    return (
      <>
        <ThemeSync mode="system" />
        <ResetPasswordScreen token={route.token} />
      </>
    );
  }
  return <AuthGate runtime={runtime} />;
}

export function App() {
  const [runtime] = useState(getRuntime);
  return (
    <AuthProvider auth={runtime.auth}>
      <MotionConfig reducedMotion="user">
        <TooltipProvider>
          <Routes runtime={runtime} />
          <Toaster />
        </TooltipProvider>
      </MotionConfig>
    </AuthProvider>
  );
}
