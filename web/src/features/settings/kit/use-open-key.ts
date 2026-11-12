"use client";

import { useState } from "react";

/**
 * A key that changes each time [open] turns on, so a dialog's form starts
 * clean on every opening while its closing animation still plays.
 */
export function useOpenKey(open: boolean): number {
  const [state, setState] = useState({ open, key: 0 });
  if (open !== state.open) {
    const next = { open, key: open ? state.key + 1 : state.key };
    setState(next);
    return next.key;
  }
  return state.key;
}
