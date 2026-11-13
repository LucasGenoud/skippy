import { describe, expect, it } from "vitest";
import { firstInvalidField, nextOnEnter, validateLogin, validateReset } from "./form-rules";
import { checkServerUrl, displayUrl } from "./server-url";

const filled = { name: "Ada", email: "ada@example.test", password: "secret1", confirm: "secret1" };

describe("validateLogin", () => {
  it("flags every empty field at once, name only when creating", () => {
    expect(validateLogin("signIn", { name: "", email: " ", password: "", confirm: "" })).toEqual({
      email: "Enter your email",
      password: "Enter your password",
    });
    expect(validateLogin("create", { name: "  ", email: "", password: "", confirm: "" })).toEqual({
      name: "Enter your name",
      email: "Enter your email",
      password: "Enter your password",
    });
  });

  it("leaves password rules to the server when signing in", () => {
    expect(validateLogin("signIn", { ...filled, password: "x", confirm: "" })).toEqual({});
  });

  it("asks a new account for six characters typed twice", () => {
    expect(validateLogin("create", { ...filled, password: "12345", confirm: "12345" })).toEqual({ password: "Use at least 6 characters" });
    expect(validateLogin("create", { ...filled, confirm: "secret2" })).toEqual({ confirm: "Passwords don't match" });
    expect(validateLogin("create", filled)).toEqual({});
  });

  it("focuses the first field in form order", () => {
    expect(firstInvalidField({ password: "x", email: "y" })).toBe("email");
    expect(firstInvalidField({})).toBeNull();
  });
});

describe("nextOnEnter", () => {
  it("walks the fields and submits from the last one", () => {
    expect(nextOnEnter("create", "name")).toBe("email");
    expect(nextOnEnter("signIn", "email")).toBe("password");
    expect(nextOnEnter("signIn", "password")).toBe("submit");
    expect(nextOnEnter("create", "password")).toBe("confirm");
    expect(nextOnEnter("create", "confirm")).toBe("submit");
  });
});

describe("validateReset", () => {
  it("needs a password at the server's floor, typed twice", () => {
    expect(validateReset("", "")).toEqual({ password: "Choose a password" });
    expect(validateReset("abc", "abc")).toEqual({ password: "Use at least 6 characters" });
    expect(validateReset("abcdef", "abcdeg")).toEqual({ confirm: "Passwords don't match" });
    expect(validateReset("abcdef", "abcdef")).toEqual({});
  });
});

describe("server addresses", () => {
  it("displays without scheme or trailing slash", () => {
    expect(displayUrl("https://notes.example.com/")).toBe("notes.example.com");
    expect(displayUrl("http://10.0.0.2:8787")).toBe("10.0.0.2:8787");
  });

  it("accepts http(s) origins and sub-paths, normalized", () => {
    expect(checkServerUrl(" https://Notes.Example.com/ ")).toEqual({ ok: true, url: "https://notes.example.com" });
    expect(checkServerUrl("http://localhost:8787/skippy/")).toEqual({ ok: true, url: "http://localhost:8787/skippy" });
  });

  it("refuses what cannot be a server address", () => {
    expect(checkServerUrl("")).toMatchObject({ ok: false });
    expect(checkServerUrl("notes.example.com")).toMatchObject({ ok: false, error: expect.stringContaining("https://") });
    expect(checkServerUrl("ftp://example.com")).toMatchObject({ ok: false });
    expect(checkServerUrl("https://")).toMatchObject({ ok: false });
    expect(checkServerUrl("https://example.com/?x=1")).toMatchObject({ ok: false });
  });
});
