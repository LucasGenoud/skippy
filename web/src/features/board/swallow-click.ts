/** Long enough for the click a touch release synthesises after touchend. */
const SWALLOW_WINDOW_MS = 350;

/**
 * Swallows the one click that follows a drag's release, in the capture phase:
 * letting go of a carried card is not a tap on it.
 */
export function swallowNextClick(): void {
  const swallow = (event: MouseEvent): void => {
    event.stopPropagation();
    event.preventDefault();
  };
  window.addEventListener("click", swallow, { capture: true, once: true });
  window.setTimeout(() => window.removeEventListener("click", swallow, { capture: true }), SWALLOW_WINDOW_MS);
}
