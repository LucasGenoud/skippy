import { useEffect } from "react";
import { act, render } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { useOverlayPresence, type OverlayPresence } from "@/components/common/overlay-presence";
import { EXIT_TIMEOUT_MS } from "@/lib/theme/motion";
import { OverlayOutlet, type OverlayEntry } from "./overlay-outlet";

// The overlay slot: an overlay that asks for presence stays mounted after its
// route goes, until it releases itself; one that does not is removed at once.

const presences = new Map<string, OverlayPresence>();

function Aware({ name }: { name: string }) {
  const presence = useOverlayPresence();
  useEffect(() => {
    presences.set(name, presence);
  });
  return <div data-overlay={name} data-present={String(presence.present)} />;
}

function Plain({ name }: { name: string }) {
  return <div data-overlay={name} />;
}

const aware = (name: string): OverlayEntry => ({ key: name, node: <Aware name={name} /> });
const plain = (name: string): OverlayEntry => ({ key: name, node: <Plain name={name} /> });

function shown(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll("[data-overlay]")).map((el) => `${el.getAttribute("data-overlay")}:${el.getAttribute("data-present") ?? "-"}`);
}

it("keeps a presence-aware overlay until it releases itself", () => {
  const view = render(<OverlayOutlet entry={aware("a")} />);
  expect(shown(view.container)).toEqual(["a:true"]);

  // Releasing while still current does nothing.
  act(() => presences.get("a")?.safeToRemove());
  expect(shown(view.container)).toEqual(["a:true"]);

  view.rerender(<OverlayOutlet entry={null} />);
  expect(shown(view.container)).toEqual(["a:false"]);

  act(() => presences.get("a")?.safeToRemove());
  expect(shown(view.container)).toEqual([]);
});

it("removes an overlay that does not ask for presence at once", () => {
  const view = render(<OverlayOutlet entry={plain("a")} />);
  view.rerender(<OverlayOutlet entry={null} />);
  expect(shown(view.container)).toEqual([]);
});

it("mounts the next overlay beside the one leaving, and drops a leaving twin", () => {
  const view = render(<OverlayOutlet entry={aware("a")} />);
  view.rerender(<OverlayOutlet entry={aware("b")} />);
  expect(shown(view.container)).toEqual(["a:false", "b:true"]);

  // Back to a while it is still leaving: one a, current.
  view.rerender(<OverlayOutlet entry={aware("a")} />);
  expect(shown(view.container)).toEqual(["b:false", "a:true"]);
});

it("removes a leaving overlay that never reports back", () => {
  vi.useFakeTimers();
  try {
    const view = render(<OverlayOutlet entry={aware("a")} />);
    view.rerender(<OverlayOutlet entry={null} />);
    expect(shown(view.container)).toEqual(["a:false"]);
    act(() => {
      vi.advanceTimersByTime(EXIT_TIMEOUT_MS);
    });
    expect(shown(view.container)).toEqual([]);
  } finally {
    vi.useRealTimers();
  }
});
