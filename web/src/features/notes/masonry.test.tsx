import { cleanup, render } from "@testing-library/react";
import { afterEach, beforeEach, expect, it } from "vitest";
import { Masonry } from "./masonry";
import { ESTIMATED_CARD_HEIGHT } from "./masonry-layout";

// Cards are placed from guessed heights until they measure. The measured
// layout must be committed in the observer's own callback, which runs before
// the browser paints, so a frame of overlapping guesses is never drawn.

type Callback = (entries: ResizeObserverEntry[]) => void;

let observers: { callback: Callback; elements: Element[] }[] = [];

beforeEach(() => {
  observers = [];
  class Observer {
    private readonly record: { callback: Callback; elements: Element[] };
    constructor(callback: Callback) {
      this.record = { callback, elements: [] };
      observers.push(this.record);
    }
    observe(element: Element): void {
      this.record.elements.push(element);
    }
    unobserve(element: Element): void {
      this.record.elements = this.record.elements.filter((e) => e !== element);
    }
    disconnect(): void {
      this.record.elements = [];
    }
  }
  Object.assign(globalThis, { ResizeObserver: Observer });
});

afterEach(cleanup);

function entry(target: Element, height: number): ResizeObserverEntry {
  return { target, borderBoxSize: [{ inlineSize: 200, blockSize: height }], contentRect: { width: 200, height } } as unknown as ResizeObserverEntry;
}

const SPACING = 8;

it("commits measured card heights before the next paint, through one observer", () => {
  const { container } = render(
    <Masonry
      ids={["a", "b"]}
      spans={new Map()}
      columns={1}
      spacing={SPACING}
      renderCard={(id) => <div>{id}</div>}
      dragEnabled={false}
      draggableIds={null}
      groupIds={new Set()}
      canReorder={false}
      onReorder={() => undefined}
      onLongPress={() => undefined}
      raisedId={null}
    />,
  );
  const grid = container.querySelector<HTMLElement>("[style*='height']")!;
  expect(grid.style.height).toBe(`${ESTIMATED_CARD_HEIGHT * 2 + SPACING}px`);

  // Every card reports to one shared observer, in one callback.
  const cardObservers = observers.filter((o) => o.elements.length > 0 && !o.elements.includes(grid));
  expect(cardObservers).toHaveLength(1);
  const [observer] = cardObservers;
  observer!.callback(observer!.elements.map((element) => entry(element, 300)));

  // No frame has run: the new layout is already in the DOM.
  expect(grid.style.height).toBe(`${300 * 2 + SPACING}px`);
});
