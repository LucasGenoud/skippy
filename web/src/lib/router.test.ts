import { afterEach, describe, expect, it } from "vitest";
import { getRoute, navigate, parseRoute, routePath } from "./router";

// Route parsing (with `util/public_route.dart`'s hex-only tokens) and
// navigation over window.history.

describe("parseRoute", () => {
  it("reads every route in the table", () => {
    expect(parseRoute("/")).toEqual({ name: "home" });
    expect(parseRoute("/n/abc")).toEqual({ name: "note", noteId: "abc" });
    expect(parseRoute("/n/abc/history")).toEqual({ name: "history", noteId: "abc" });
    expect(parseRoute("/settings")).toEqual({ name: "settings", page: null });
    expect(parseRoute("/settings/ai")).toEqual({ name: "settings", page: "ai" });
    expect(parseRoute("/settings/bogus")).toEqual({ name: "settings", page: null });
    expect(parseRoute("/workspaces/w1/settings")).toEqual({ name: "workspaceSettings", workspaceId: "w1" });
    expect(parseRoute("/workspaces/w1/stats")).toEqual({ name: "workspaceStats", workspaceId: "w1" });
    expect(parseRoute("/chat")).toEqual({ name: "chat" });
    expect(parseRoute("/somewhere/else")).toEqual({ name: "home" });
  });

  it("accepts only hex tokens for public links, tolerating a sub-path", () => {
    expect(parseRoute("/s/abc123")).toEqual({ name: "publicShare", token: "abc123" });
    expect(parseRoute("/notes/s/ABC/")).toEqual({ name: "publicShare", token: "ABC" });
    expect(parseRoute("/reset/0f0f?x=1")).toEqual({ name: "resetPassword", token: "0f0f" });
    expect(parseRoute("/s/not-hex")).toEqual({ name: "home" });
    expect(parseRoute("/s/")).toEqual({ name: "home" });
    expect(parseRoute("/s/deadBEEF42?utm=1")).toEqual({ name: "publicShare", token: "deadBEEF42" });
    expect(parseRoute("/notes/n/xyz")).toEqual({ name: "note", noteId: "xyz" });
  });

  it("round-trips paths", () => {
    expect(routePath({ name: "history", noteId: "a b" })).toBe("/n/a%20b/history");
    expect(parseRoute(routePath({ name: "workspaceStats", workspaceId: "w" }))).toEqual({ name: "workspaceStats", workspaceId: "w" });
  });
});

describe("navigate", () => {
  afterEach(() => window.history.replaceState(null, "", "/"));

  it("pushes and replaces entries, keeping a deployment's base path", () => {
    window.history.replaceState(null, "", "/app/");
    navigate("/n/x");
    expect(window.location.pathname).toBe("/app/n/x");
    expect(getRoute()).toEqual({ name: "note", noteId: "x" });
    navigate({ name: "settings", page: "about" }, { replace: true });
    expect(window.location.pathname).toBe("/app/settings/about");
  });
});
