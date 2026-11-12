"use client";

import { memo, useRef, type CSSProperties } from "react";
import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { motion, useReducedMotion, type Variants } from "motion/react";
import { cn } from "cn";

import { NoteCard } from "@/features/notes/note-card";
import { useUiController } from "@/lib/store";
import { DURATION, EASE, TRANSITION, cssEase, transitionFor } from "@/lib/theme/motion";

import { swallowNextClick } from "./swallow-click";

// One card on the board: a dnd-kit sortable around the shared NoteCard.
//
//   motion.div   enter/exit and layout glide (a card added, removed, re-sorted)
//     div        dnd-kit's transform while a drag makes room
//       NoteCard
//
// The two transforms live on different elements so they compose rather than
// fight. While a card is in the air, cards moving between columns appear and
// disappear at once: the drag itself is the animation.

const ENTER_SCALE = 0.96;
/** A touch held this long selects a card that cannot be dragged (`onStationaryLongPress`). */
const LONG_PRESS_MS = 500;

const presence: Variants = {
  hidden: (dragging: boolean) => (dragging ? { opacity: 1, scale: 1 } : { opacity: 0, scale: ENTER_SCALE }),
  shown: { opacity: 1, scale: 1 },
  gone: (dragging: boolean) => (dragging ? { opacity: 0, transition: { duration: 0 } } : { opacity: 0, scale: ENTER_SCALE }),
};

export const BoardCard = memo(function BoardCard({
  noteId,
  dragEnabled,
  dragging,
  dimmed,
}: {
  noteId: string;
  dragEnabled: boolean;
  /** A card is in the air somewhere on the board. */
  dragging: boolean;
  /** Carried along with the selection; faded where it sits. */
  dimmed: boolean;
}) {
  const reduced = useReducedMotion();
  const { listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: noteId,
    data: { type: "card" },
    disabled: !dragEnabled,
    transition: reduced ? null : { duration: DURATION.base, easing: cssEase(EASE.emphasized) },
  });
  const style: CSSProperties = { transform: CSS.Translate.toString(transform), transition };
  const longPress = useLongPressSelect(noteId, !dragEnabled);
  // Pointer listeners only: the card keeps its own keys (Enter opens, Space
  // selects) and its own role; the keyboard path to another column is the
  // "Move to column" picker.
  const handle = dragEnabled && listeners ? { onMouseDown: listeners.onMouseDown, onTouchStart: listeners.onTouchStart } : undefined;

  return (
    <motion.div
      layout={reduced ? false : "position"}
      custom={dragging}
      variants={presence}
      initial="hidden"
      animate="shown"
      exit="gone"
      transition={transitionFor(TRANSITION.base, reduced)}
    >
      <div
        ref={setNodeRef}
        style={style}
        data-board-card={noteId}
        {...longPress}
        className={cn("touch-manipulation transition-opacity duration-150 ease-standard", (isDragging || dimmed) && "opacity-40")}
      >
        <NoteCard noteId={noteId} variant="board" dragHandleProps={handle} />
      </div>
    </motion.div>
  );
});

/** Touch long-press selection for a card that cannot be dragged (a sorted board). */
function useLongPressSelect(noteId: string, enabled: boolean) {
  const ui = useUiController();
  const timer = useRef<number | null>(null);
  if (!enabled) {
    return undefined;
  }
  const cancel = (): void => {
    if (timer.current !== null) {
      window.clearTimeout(timer.current);
      timer.current = null;
    }
  };
  return {
    onTouchStart: () => {
      cancel();
      timer.current = window.setTimeout(() => {
        timer.current = null;
        ui.toggleSelected(noteId);
        swallowNextClick();
      }, LONG_PRESS_MS);
    },
    onTouchMove: cancel,
    onTouchEnd: cancel,
    onTouchCancel: cancel,
  };
}
