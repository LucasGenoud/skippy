"use client";

import { useCallback, useMemo, useState } from "react";

export interface DialogHandle<T> {
  readonly open: boolean;
  /** Changes on every show, so a `key` gives each opening fresh form state. */
  readonly key: number;
  /** What it was shown for; kept while the close animation runs. */
  readonly value: T | null;
  show(value: T): void;
  close(): void;
  onOpenChange(open: boolean): void;
}

/** Open/close state for a dialog that should start clean each time. */
export function useDialog<T = true>(): DialogHandle<T> {
  const [state, setState] = useState<{ open: boolean; key: number; value: T | null }>({ open: false, key: 0, value: null });
  const show = useCallback((value: T) => setState((s) => ({ open: true, key: s.key + 1, value })), []);
  const close = useCallback(() => setState((s) => ({ ...s, open: false })), []);
  const onOpenChange = useCallback((open: boolean) => setState((s) => ({ ...s, open })), []);
  return useMemo(() => ({ ...state, show, close, onOpenChange }), [state, show, close, onOpenChange]);
}
