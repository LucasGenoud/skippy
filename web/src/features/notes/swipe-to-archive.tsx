"use client";

import { useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { Archive, ArchiveArrowUp } from "lucide-react";
import { animate, motion, useMotionValue, useReducedMotion, useTransform } from "motion/react";
import { cn } from "cn";

import { DURATION, EASE } from "@/lib/theme/motion";

import { swipeCommitDistance, swipeOpacity, swipeOutcome } from "./card-rules";

/** Movement before a touch is read as a horizontal swipe rather than a tap or scroll. */
const SLOP = 10;
/** Horizontal must beat vertical by this much to claim the gesture. */
const AXIS_BIAS = 1.2;
const CHIP = 40;

interface Track {
  pointerId: number;
  startX: number;
  startY: number;
  lastX: number;
  lastT: number;
  velocity: number;
  claimed: boolean;
  width: number;
  height: number;
}

/**
 * A horizontal swipe across a card that archives it, either way
 * (`swipe_to_archive.dart`). Touch only. Disabled, it ignores the pointer but
 * keeps the same elements, so toggling it never remounts the card.
 * An archived note swipes back out of the archive.
 */
export function SwipeToArchive({
  enabled,
  archived,
  onArchive,
  onActive,
  children,
}: {
  enabled: boolean;
  archived: boolean;
  onArchive: () => void;
  /** True while the card is off its slot, so a grid can paint it above its neighbours. */
  onActive?: (active: boolean) => void;
  children: ReactNode;
}) {
  const reduced = useReducedMotion();
  const x = useMotionValue(0);
  const track = useRef<Track | null>(null);
  const [pointerY, setPointerY] = useState(0);
  const [size, setSize] = useState({ width: 1, height: 1 });
  const [leaving, setLeaving] = useState(false);
  const opacity = useTransform(x, (v) => swipeOpacity(v / size.width));
  const progress = useTransform(x, (v) => Math.min(1, Math.abs(v) / Math.max(1, swipeCommitDistance(size.width))));
  const panelOpacity = useTransform(progress, (p) => (p <= 0 ? 0 : 1));
  const warmth = useTransform(progress, (p) => p * p * p);
  const iconScale = useTransform(progress, (p) => 0.7 + 0.3 * p);
  const [toTrailing, setToTrailing] = useState(true);

  const glide = (to: number, duration: number, ease: readonly number[]) =>
    animate(x, to, { duration: reduced ? 0 : duration / 1000, ease: [...ease] as [number, number, number, number] });

  const settleBack = async (): Promise<void> => {
    await glide(0, DURATION.fast, EASE.standard);
    onActive?.(false);
  };

  const commit = async (direction: number): Promise<void> => {
    setLeaving(true);
    await glide((direction === 0 ? 1 : direction) * size.width, DURATION.base, EASE.emphasized);
    onArchive();
    // Most views drop the note now; one that keeps it (a label lists archived
    // notes too) would otherwise show a hole, so slide it back after a frame.
    await new Promise((resolve) => requestAnimationFrame(resolve));
    await glide(0, DURATION.base, EASE.emphasized);
    setLeaving(false);
    onActive?.(false);
  };

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>): void => {
    if (!enabled || event.pointerType !== "touch" || track.current) {
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    track.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      lastX: event.clientX,
      lastT: event.timeStamp,
      velocity: 0,
      claimed: false,
      width: rect.width,
      height: rect.height,
    };
    setPointerY(event.clientY - rect.top);
  };

  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const t = track.current;
    if (!t || t.pointerId !== event.pointerId) {
      return;
    }
    const dx = event.clientX - t.startX;
    const dy = event.clientY - t.startY;
    if (!t.claimed) {
      if (Math.abs(dy) > SLOP && Math.abs(dy) >= Math.abs(dx)) {
        track.current = null; // a scroll
        return;
      }
      if (Math.abs(dx) < SLOP || Math.abs(dx) < Math.abs(dy) * AXIS_BIAS) {
        return;
      }
      t.claimed = true;
      event.currentTarget.setPointerCapture(event.pointerId);
      setSize({ width: t.width, height: t.height });
      onActive?.(true);
    }
    const dt = Math.max(1, event.timeStamp - t.lastT);
    t.velocity = ((event.clientX - t.lastX) / dt) * 1000;
    t.lastX = event.clientX;
    t.lastT = event.timeStamp;
    const offset = Math.max(-t.width, Math.min(t.width, dx));
    setToTrailing(offset > 0);
    x.set(offset);
  };

  const onPointerEnd = (event: ReactPointerEvent<HTMLDivElement>, cancelled: boolean): void => {
    const t = track.current;
    if (!t || t.pointerId !== event.pointerId) {
      return;
    }
    track.current = null;
    if (!t.claimed) {
      return;
    }
    const travelled = x.get();
    if (!cancelled && swipeOutcome(travelled, t.width, t.velocity) === "commit") {
      void commit(Math.sign(travelled));
    } else {
      void settleBack();
    }
  };

  const top = Math.max(0, Math.min(pointerY - CHIP / 2, size.height - CHIP));
  const Icon = archived ? ArchiveArrowUp : Archive;

  return (
    <div
      className="relative touch-pan-y"
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={(e) => onPointerEnd(e, false)}
      onPointerCancel={(e) => onPointerEnd(e, true)}
      onClickCapture={(event) => {
        // The tap that ends a swipe is not a tap on the card.
        if (x.get() !== 0) {
          event.stopPropagation();
        }
      }}
    >
      <motion.div aria-hidden className="absolute inset-0 overflow-hidden rounded-md bg-secondary-container" style={{ opacity: leaving ? opacity : panelOpacity }}>
        <motion.div className="absolute inset-0 bg-primary-container" style={{ opacity: warmth }} />
        <div className={cn("absolute flex items-center justify-center", toTrailing ? "left-0" : "right-0")} style={{ top, width: CHIP + 12, height: CHIP }}>
          <motion.span className="relative inline-flex text-on-primary-container" style={{ scale: iconScale }}>
            <Icon className="size-[22px]" />
          </motion.span>
        </div>
      </motion.div>
      <motion.div style={{ x, opacity }}>{children}</motion.div>
    </div>
  );
}
