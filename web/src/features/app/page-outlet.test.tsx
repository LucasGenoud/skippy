import { act, render } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { PageOutlet } from "./page-outlet";

// Escape goes back from a full page through its own Back button, but leaves
// a text field's Escape alone.

it("presses the page's Back button on Escape, except while typing", () => {
  const back = vi.fn();
  const view = render(
    <PageOutlet
      onCovered={() => {}}
      entry={{
        key: "settings",
        node: (
          <div>
            <button type="button" data-page-back onClick={back}>
              Back
            </button>
            <input aria-label="Name" />
          </div>
        ),
      }}
    />,
  );

  const field = view.getByLabelText("Name");
  act(() => {
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(back).not.toHaveBeenCalled();

  act(() => {
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(back).toHaveBeenCalledTimes(1);
});
