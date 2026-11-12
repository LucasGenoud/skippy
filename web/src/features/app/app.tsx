"use client";

import { useState, useSyncExternalStore } from "react";
import { MotionConfig } from "motion/react";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useRoute } from "@/lib/router";
import { AuthProvider, useAuth } from "@/lib/store/hooks";
import { LoginScreen, ResetPasswordScreen } from "@/features/auth";
import { PublicShareScreen } from "@/features/public";
import { getRuntime, type Runtime } from "./runtime";
import { SignedInApp } from "./signed-in-app";
import { Splash } from "./splash";
import { ThemeSync } from "./theme-sync";

// The app root. Public routes render without auth; everything else goes
// through the auth gate, which mounts the signed-in user's stores.

function AuthGate({ runtime }: { runtime: Runtime }) {
  const status = useAuth((s) => s.status);
  const session = useSyncExternalStore(runtime.sessions.subscribe, runtime.sessions.get, runtime.sessions.get);
  if (status === "restoring") {
    return <Splash />;
  }
  if (status === "signedOut" || session === null) {
    return (
      <>
        <ThemeSync mode="system" />
        <LoginScreen />
      </>
    );
  }
  return <SignedInApp key={session.userId} session={session} />;
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
