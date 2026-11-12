import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, expect, it } from "vitest";
import { MemoryKeyValueStore } from "@/lib/state/local-cache";
import { getRoute, useRoute } from "@/lib/router";
import { AuthStore, type PreferenceStorage } from "@/lib/store/auth-store";
import { AuthProvider, SessionProvider } from "@/lib/store/hooks";
import { Session } from "@/lib/store/session";
import { FakeApi } from "@/tests/fake-api";
import { SettingsScreen } from "./settings-screen";

class MemoryPrefs implements PreferenceStorage {
  readonly values = new Map<string, string>();
  getItem(key: string): string | null {
    return this.values.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }
  removeItem(key: string): void {
    this.values.delete(key);
  }
}

let wide = false;
let api: FakeApi;
let session: Session;
let auth: AuthStore;

beforeEach(async () => {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({ matches: wide, media: query, addEventListener() {}, removeEventListener() {} }),
  });
  api = new FakeApi();
  auth = new AuthStore(api, new MemoryPrefs());
  session = new Session({ api, userId: "u-me", cache: new MemoryKeyValueStore(), accountOrigin: "existing", restoredSession: false, offlineGraceMs: 20 });
  await session.notes.load();
  window.history.replaceState(null, "", "/settings");
});

afterEach(() => {
  cleanup();
  session.dispose();
  window.history.replaceState(null, "", "/");
});

function Routed() {
  const route = useRoute();
  return <SettingsScreen page={route.name === "settings" ? (route.page ?? undefined) : undefined} />;
}

const mount = () =>
  render(
    <AuthProvider auth={auth}>
      <SessionProvider session={session}>
        <Routed />
      </SessionProvider>
    </AuthProvider>,
  );

it("opens one page at a time on a phone, pushed over the index", async () => {
  wide = false;
  mount();
  expect(screen.getByRole("navigation", { name: "Settings pages" })).toBeTruthy();
  await act(async () => fireEvent.click(screen.getByText("About")));
  expect(getRoute()).toEqual({ name: "settings", page: "about" });
  expect(screen.queryByRole("navigation", { name: "Settings pages" })).toBeNull();
  expect(screen.getByText("Client version")).toBeTruthy();
});

it("keeps the index beside the page on a wide window, Account first", async () => {
  wide = true;
  mount();
  expect(screen.getByRole("navigation", { name: "Settings pages" })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Account" }).getAttribute("aria-current")).toBe("page");
  await act(async () => fireEvent.click(screen.getByRole("button", { name: "About" })));
  expect(getRoute()).toEqual({ name: "settings", page: "about" });
  expect(screen.getByRole("button", { name: "About" }).getAttribute("aria-current")).toBe("page");
});
