import { act, render } from "@testing-library/react";
import { beforeAll, expect, it, vi } from "vitest";
import { App } from "./app";

// The root's routing: public pages render without auth, everything else goes
// through the auth gate (signed out here: no saved token). The feature
// screens are stubbed so this keeps passing as they are built out.

vi.mock("@/features/public", () => ({
  PublicShareScreen: ({ token }: { token: string }) => <div data-placeholder="public-share" data-token={token} />,
}));
vi.mock("@/features/auth", () => ({
  LoginScreen: () => <div data-placeholder="login" />,
  ResetPasswordScreen: ({ token }: { token: string }) => <div data-placeholder="reset-password" data-token={token} />,
}));

beforeAll(() => {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({ matches: false, media: query, addEventListener() {}, removeEventListener() {} }),
  });
});

it("shows a public share without signing in, and the login when signed out", async () => {
  window.history.replaceState(null, "", "/s/abc123");
  const view = render(<App />);
  expect(view.container.querySelector('[data-placeholder="public-share"]')?.getAttribute("data-token")).toBe("abc123");

  await act(async () => {
    window.history.pushState(null, "", "/");
    window.dispatchEvent(new PopStateEvent("popstate"));
  });
  expect(view.container.querySelector('[data-placeholder="login"]')).not.toBeNull();
  view.unmount();
  window.history.replaceState(null, "", "/");
});
