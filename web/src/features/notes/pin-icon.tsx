"use client";

import { Pin } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { cn } from "cn";

import { TRANSITION } from "@/lib/theme/motion";

/**
 * The pin glyph, filled when pinned, with a small pop when it flips so pinning
 * reads as tactile rather than a glyph swap (`pin_icon.dart`).
 */
export function PinIcon({ pinned, className }: { pinned: boolean; className?: string }) {
  return (
    <span className={cn("relative inline-flex size-[18px] items-center justify-center", className)}>
      <AnimatePresence initial={false} mode="popLayout">
        <motion.span
          key={pinned ? "pinned" : "unpinned"}
          className="inline-flex"
          initial={{ scale: 0, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          exit={{ scale: 0, opacity: 0 }}
          transition={TRANSITION.pop}
        >
          <Pin aria-hidden className="size-[18px]" fill={pinned ? "currentColor" : "none"} />
        </motion.span>
      </AnimatePresence>
    </span>
  );
}
