import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/lib/api/errors";
import { FakeApi } from "@/tests/fake-api";
import { AuthStore, type PreferenceStorage } from "./auth-store";

// Ported from `app/test/auth_store_test.dart`.

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

let api: FakeApi;
let prefs: MemoryPrefs;
let auth: AuthStore;

beforeEach(() => {
  api = new FakeApi();
  prefs = new MemoryPrefs();
  auth = new AuthStore(api, prefs);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("account origin", () => {
  it("marks a registered account as just created, a sign-in as existing", async () => {
    expect(await auth.registerAccount("Ada", "ada@example.test", "pw")).toBe(true);
    expect(auth.state).toMatchObject({ status: "signedIn", accountOrigin: "justCreated" });
    expect(api.token).toBe("t-ada@example.test");
    auth.signOut();
    expect(await auth.signIn("ada@example.test", "pw")).toBe(true);
    expect(auth.state.accountOrigin).toBe("existing");
  });
});

describe("restore", () => {
  it("opens a cached session without waiting for the server", async () => {
    prefs.setItem("sticky_notes_token", "t1");
    prefs.setItem("sticky_notes_user", JSON.stringify({ id: "u-me", name: "Me", email: "me@x" }));
    api.failWith = new TypeError("Failed to fetch");
    await auth.restore();
    expect(auth.state).toMatchObject({ status: "signedIn", restoredSession: true });
    expect(auth.state.user?.id).toBe("u-me");
    await Promise.resolve();
    expect(auth.state.status).toBe("signedIn");
  });

  it("signs out once the server rejects the token", async () => {
    prefs.setItem("sticky_notes_token", "t1");
    prefs.setItem("sticky_notes_user", JSON.stringify({ id: "u-me", name: "Me", email: "me@x" }));
    api.failWith = new ApiError(401, "");
    await auth.restore();
    await vi.waitFor(() => expect(auth.state.status).toBe("signedOut"));
    expect(prefs.getItem("sticky_notes_token")).toBeNull();
  });

  it("keeps the session on a server error", async () => {
    prefs.setItem("sticky_notes_token", "t1");
    prefs.setItem("sticky_notes_user", JSON.stringify({ id: "u-me", name: "Me", email: "me@x" }));
    api.failWith = new ApiError(500, "");
    await auth.restore();
    await Promise.resolve();
    expect(auth.state.status).toBe("signedIn");
  });

  it("without a cached profile, asks the server who the token belongs to", async () => {
    prefs.setItem("sticky_notes_token", "t1");
    await auth.restore();
    expect(auth.state.user?.id).toBe("u-me");
    expect(prefs.getItem("sticky_notes_user")).not.toBeNull();
  });

  it("with no saved token, is signed out", async () => {
    await auth.restore();
    expect(auth.state.status).toBe("signedOut");
  });
});

describe("errors", () => {
  it("words a wrong password and a taken email, and shows the status otherwise", async () => {
    api.failWith = new ApiError(401, "");
    await auth.signIn("a@b", "x");
    expect(auth.state).toMatchObject({ error: "Wrong email or password", errorStatus: 401 });
    api.failWith = new ApiError(409, "");
    await auth.registerAccount("A", "a@b", "x");
    expect(auth.state.error).toBe("That email is already registered");
    api.failWith = new ApiError(404, "");
    await auth.signIn("a@b", "x");
    expect(auth.state.error).toContain("(404)");
  });

  it("a 401 on the current token ends the session", async () => {
    await auth.signIn("a@b", "x");
    api.onUnauthorized?.();
    expect(auth.state.status).toBe("signedOut");
  });
});

describe("server list", () => {
  it("keeps the active server listed, edits in place, refuses duplicates", () => {
    auth.loadSavedUrls();
    expect(auth.state.savedUrls).toEqual(["http://fake.test"]);
    auth.addUrl("http://second.test/");
    expect(auth.state.activeUrl).toBe("http://second.test");
    expect(auth.state.savedUrls).toEqual(["http://fake.test", "http://second.test"]);
    auth.editUrl("http://fake.test", "http://first.test");
    expect(auth.state.savedUrls).toEqual(["http://first.test", "http://second.test"]);
    auth.editUrl("http://first.test", "http://second.test");
    expect(auth.state.savedUrls).toEqual(["http://first.test", "http://second.test"]);
    auth.removeUrl("http://second.test");
    expect(auth.state.savedUrls).toHaveLength(2);
    auth.removeUrl("http://first.test");
    expect(auth.state.savedUrls).toEqual(["http://second.test"]);
  });

  it("switching servers signs out and invalidates an in-flight login", async () => {
    auth.loadSavedUrls();
    const login = auth.signIn("a@b", "x");
    auth.addUrl("http://other.test");
    expect(await login).toBe(false);
    expect(auth.state.status).toBe("signedOut");
  });
});
