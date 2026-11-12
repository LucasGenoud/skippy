import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { ApiError } from "@/lib/api/errors";
import { AuthStore, type PreferenceStorage } from "@/lib/store/auth-store";
import { AuthProvider } from "@/lib/store/hooks";
import { FakeApi } from "@/tests/fake-api";
import { LoginScreen } from "./login-screen";
import { ResetPasswordScreen } from "./reset-password-screen";

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
let auth: AuthStore;

beforeAll(() => {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({ matches: false, media: query, addEventListener() {}, removeEventListener() {} }),
  });
});

beforeEach(() => {
  api = new FakeApi();
  auth = new AuthStore(api, new MemoryPrefs());
  auth.loadSavedUrls();
});

afterEach(() => {
  cleanup();
  window.history.replaceState(null, "", "/");
});

async function renderLogin() {
  const view = render(
    <AuthProvider auth={auth}>
      <LoginScreen />
    </AuthProvider>,
  );
  // Let the capabilities probe settle.
  await act(async () => {});
  return view;
}

const field = (label: string): HTMLInputElement => screen.getByLabelText(label) as HTMLInputElement;

describe("LoginScreen", () => {
  it("moves through the fields on Enter and signs in from the password", async () => {
    await renderLogin();
    const email = field("Email");
    expect(document.activeElement).toBe(email);

    fireEvent.change(email, { target: { value: "ada@example.test" } });
    fireEvent.keyDown(email, { key: "Enter" });
    expect(document.activeElement).toBe(field("Password"));

    fireEvent.change(field("Password"), { target: { value: "pw" } });
    await act(async () => {
      fireEvent.submit(field("Password").form!);
    });
    expect(api.log).toContain("login");
    expect(auth.state.status).toBe("signedIn");
  });

  it("flags empty fields inline instead of submitting", async () => {
    await renderLogin();
    await act(async () => {
      fireEvent.submit(field("Email").form!);
    });
    expect(screen.getByText("Enter your email")).toBeTruthy();
    expect(screen.getByText("Enter your password")).toBeTruthy();
    expect(api.log).not.toContain("login");
    expect(document.activeElement).toBe(field("Email"));

    fireEvent.change(field("Email"), { target: { value: "a" } });
    expect(field("Email").getAttribute("aria-invalid")).toBeNull();
  });

  it("offers a reset link only where the server can send one", async () => {
    await renderLogin();
    expect(screen.queryByText("Forgot password?")).toBeNull();
    cleanup();

    api.capabilities = { ...api.capabilities, passwordReset: true };
    await renderLogin();
    expect(screen.getByText("Forgot password?")).toBeTruthy();
  });

  it("shows the server's refusal and outlines the rejected fields", async () => {
    await renderLogin();
    api.failWith = new ApiError(401, '{"error":"invalid credentials"}');
    fireEvent.change(field("Email"), { target: { value: "ada@example.test" } });
    fireEvent.change(field("Password"), { target: { value: "nope" } });
    await act(async () => {
      fireEvent.submit(field("Password").form!);
    });
    expect(screen.getByRole("alert").textContent).toContain("Wrong email or password");
    expect(field("Email").getAttribute("aria-invalid")).toBe("true");
    expect(field("Password").getAttribute("aria-invalid")).toBe("true");
  });

  it("prefills the address a reset was for and focuses the password", async () => {
    auth.setPrefillEmail("ada@example.test");
    await renderLogin();
    expect(field("Email").value).toBe("ada@example.test");
    expect(document.activeElement).toBe(field("Password"));
    expect(auth.state.prefillEmail).toBeNull();
  });
});

describe("ResetPasswordScreen", () => {
  function renderReset(token: string) {
    window.history.replaceState(null, "", `/reset/${token}`);
    return render(
      <AuthProvider auth={auth}>
        <ResetPasswordScreen token={token} api={api} />
      </AuthProvider>,
    );
  }

  it("sets the password, then sends the address to the sign-in form", async () => {
    api.resetTokens.set("abc", "ada@example.test");
    renderReset("abc");
    fireEvent.change(field("New password"), { target: { value: "secret1" } });
    fireEvent.change(field("Confirm password"), { target: { value: "secret1" } });
    await act(async () => {
      fireEvent.submit(field("New password").form!);
    });
    expect(screen.getByText("Password updated")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));
    expect(auth.state.prefillEmail).toBe("ada@example.test");
    expect(window.location.pathname).toBe("/");
  });

  it("checks the password locally before spending the link", async () => {
    renderReset("abc");
    fireEvent.change(field("New password"), { target: { value: "abc" } });
    await act(async () => {
      fireEvent.submit(field("New password").form!);
    });
    expect(screen.getByText("Use at least 6 characters")).toBeTruthy();
    expect(api.log).not.toContain("resetPassword");
  });

  it("explains an expired or used link", async () => {
    renderReset("dead");
    fireEvent.change(field("New password"), { target: { value: "secret1" } });
    fireEvent.change(field("Confirm password"), { target: { value: "secret1" } });
    await act(async () => {
      fireEvent.submit(field("New password").form!);
    });
    expect(screen.getByText("This link has expired")).toBeTruthy();
  });
});
