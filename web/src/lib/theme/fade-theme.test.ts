import { afterEach, expect, it, vi } from "vitest";
import { fadeTheme } from "./accent";

// A View Transition rejects its promises when the browser skips it (a hidden
// tab, a transition already running). Those rejections must not go unhandled.

afterEach(() => {
  Reflect.deleteProperty(document, "startViewTransition");
});

it("swallows the rejections of a skipped view transition", async () => {
  const skipped = () => Promise.reject(new DOMException("Transition was aborted", "InvalidStateError"));
  const unhandled = vi.fn();
  process.on("unhandledRejection", unhandled);
  Object.defineProperty(document, "startViewTransition", {
    configurable: true,
    value: (update: () => void) => {
      update();
      return { ready: skipped(), finished: skipped(), updateCallbackDone: skipped(), skipTransition() {} };
    },
  });
  const change = vi.fn();

  fadeTheme(change);
  await new Promise((resolve) => setTimeout(resolve, 0));

  process.off("unhandledRejection", unhandled);
  expect(change).toHaveBeenCalledOnce();
  expect(unhandled).not.toHaveBeenCalled();
});
