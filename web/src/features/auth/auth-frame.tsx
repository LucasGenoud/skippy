"use client";

import type { ReactNode } from "react";
import { LoaderCircle } from "lucide-react";
import { motion, useReducedMotion } from "motion/react";
import { AppLogo } from "@/components/common/app-logo";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";

// The frame both signed-out forms share: the mark and name, then the form in
// a card on wide screens and edge to edge on phones, so arriving from a reset
// email looks like arriving anywhere else.

const LOGO_SIZE = 72;
const RISE_PX = 12;

export function AuthFrame({ children, footer }: { children: ReactNode; footer?: ReactNode }) {
  const reduced = useReducedMotion();
  return (
    <main className="flex min-h-dvh w-full items-center justify-center bg-canvas px-5 py-6 sm:px-6">
      <motion.div
        className="flex w-full flex-col items-stretch sm:max-w-[400px]"
        initial={{ opacity: 0, y: RISE_PX }}
        animate={{ opacity: 1, y: 0 }}
        transition={transitionFor(TRANSITION.slow, reduced)}
      >
        <AppLogo size={LOGO_SIZE} className="mx-auto" />
        <h1 className="mt-5 text-center text-2xl font-semibold tracking-tight text-on-surface">Skippy</h1>
        <div className="mt-6 sm:rounded-md sm:border sm:border-outline-variant sm:bg-surface sm:p-6 sm:shadow-card">{children}</div>
        {footer ? <div className="mt-4 flex justify-center">{footer}</div> : null}
      </motion.div>
    </main>
  );
}

/** The spinner a busy submit button shows in place of its icon. */
export function ButtonSpinner() {
  return <LoaderCircle aria-hidden className="animate-spin" />;
}
