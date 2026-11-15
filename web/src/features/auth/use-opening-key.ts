import { useState } from "react";

/**
 * A key that changes each time [open] turns true. A dialog keys its body with
 * it, so every opening starts fresh while the body stays mounted, and keeps
 * its content, through the closing animation.
 */
export function useOpeningKey(open: boolean): number {
  const [key, setKey] = useState(0);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setKey((k) => k + 1);
    }
  }
  return key;
}
