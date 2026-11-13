import { useRef, type ReactNode } from "react";
import { useIsPresent } from "motion/react";

/**
 * [children], until their view starts leaving: from then on a static copy of
 * the markup they last drew. A view reads the active collection and workspace,
 * which have already changed by the time it leaves, so a live board would
 * spend its exit redrawing itself as the collection replacing it. The copy is
 * taken in the render that starts the exit, before React commits anything.
 */
export function FrozenOnExit({ className, children }: { className?: string; children: ReactNode }) {
  const present = useIsPresent();
  const ref = useRef<HTMLDivElement>(null);
  const frozen = useRef<string | null>(null);
  if (present) {
    return (
      <div ref={ref} className={className}>
        {children}
      </div>
    );
  }
  // The old DOM, read once before the commit that replaces it.
  frozen.current ??= ref.current?.innerHTML ?? "";
  // eslint-disable-next-line react-hooks/refs -- the copy taken above, not live state.
  return <div ref={ref} className={className} inert aria-hidden dangerouslySetInnerHTML={{ __html: frozen.current }} />;
}
