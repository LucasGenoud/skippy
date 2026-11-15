import { act, cleanup, fireEvent, render, renderHook, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FormDialog } from "./kit/form-dialog";
import { useOpenKey } from "./kit/use-open-key";

afterEach(cleanup);

it("submits on Enter but not when a body button without a type is clicked", () => {
  const onSubmit = vi.fn();
  const onExtra = vi.fn();
  render(
    <FormDialog open onOpenChange={() => {}} title="Test" onSubmit={onSubmit} footer={null}>
      <Button onClick={onExtra}>Extra</Button>
      <Input aria-label="Field" />
    </FormDialog>,
  );
  fireEvent.click(screen.getByText("Extra"));
  expect(onExtra).toHaveBeenCalledOnce();
  expect(onSubmit).not.toHaveBeenCalled();

  const form = screen.getByLabelText("Field").closest("form");
  fireEvent.submit(form as HTMLFormElement);
  expect(onSubmit).toHaveBeenCalledOnce();
});

it("keeps a busy form open against Escape", () => {
  const onOpenChange = vi.fn();
  render(
    <FormDialog open onOpenChange={onOpenChange} title="Busy" busy footer={null}>
      <Input aria-label="Field" />
    </FormDialog>,
  );
  fireEvent.keyDown(screen.getByLabelText("Field"), { key: "Escape" });
  expect(onOpenChange).not.toHaveBeenCalled();
});

it("changes the open key only when a dialog opens", () => {
  const { result, rerender } = renderHook(({ open }) => useOpenKey(open), { initialProps: { open: false } });
  expect(result.current).toBe(0);
  rerender({ open: true });
  expect(result.current).toBe(1);
  act(() => rerender({ open: false }));
  expect(result.current).toBe(1);
  rerender({ open: true });
  expect(result.current).toBe(2);
});
