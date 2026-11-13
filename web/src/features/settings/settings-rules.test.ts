import { describe, expect, it } from "vitest";
import { ApiError } from "@/lib/api/errors";
import { NOTIFY_CHANNELS } from "@/lib/models";
import { DEFAULT_SETTINGS } from "@/lib/store/settings-store";
import { accountErrorText, validateAccountForm } from "./account/account-errors";
import { providerSummary } from "./ai/ai-page";
import { customTaskId } from "./ai/rewrite-tasks-dialog";
import { gridPreviewShape } from "./appearance/grid-layout";
import { importedMessage, partialMessage, progressText, restoredMessage } from "./data/data-messages";
import { initialKeepWorkspace } from "./data/keep-import-dialog";
import { plural } from "./kit/files";
import { settingsSummary } from "./pages";
import { notifyFormValues, orList, resolvedChoice, trimmedValues } from "./reminders/notify-form";
import { settingsLayout } from "./settings-screen";
import { tokenMeta } from "./sharing/ai-access-section";
import { makeWorkspace } from "@/lib/models";

describe("account form", () => {
  it("checks each field the way the Flutter dialog does", () => {
    expect(validateAccountForm("name", " A ", "", "")).toBe("Enter your full name");
    expect(validateAccountForm("name", "Ada", "", "")).toBeNull();
    expect(validateAccountForm("email", "nope", "pw", "")).toBe("Enter a valid email address");
    expect(validateAccountForm("email", "a@b", "", "")).toBe("Enter your current password");
    expect(validateAccountForm("password", "secret1", "", "secret1")).toBe("Enter your current password");
    expect(validateAccountForm("password", "short", "pw", "short")).toBe("Password must be at least 6 characters");
    expect(validateAccountForm("password", "secret1", "pw", "secret2")).toBe("Passwords don't match");
    expect(validateAccountForm("password", " secret1 ", "pw", "secret1")).toBeNull();
  });

  it("reads a 403 as a wrong password and anything else as the server's words", () => {
    expect(accountErrorText(new ApiError(403, '{"error":"forbidden"}'), "x")).toBe("Current password is incorrect");
    expect(accountErrorText(new ApiError(409, '{"error":"Email taken"}'), "x")).toBe("Email taken");
    expect(accountErrorText(new Error("boom"), "Couldn't update your account")).toBe("Couldn't update your account");
  });
});

describe("notification channels", () => {
  it("keeps every registry field and resolves blank choices to the first option", () => {
    const values = notifyFormValues({ ntfy_url: "https://ntfy.sh/x", smtp_security: "bogus" });
    for (const channel of NOTIFY_CHANNELS) {
      for (const field of channel.fields) {
        expect(field.key in values).toBe(true);
      }
    }
    expect(values.ntfy_url).toBe("https://ntfy.sh/x");
    expect(values.smtp_security).toBe("tls");
    const security = NOTIFY_CHANNELS.flatMap((c) => c.fields).find((f) => f.key === "smtp_security");
    expect(security && resolvedChoice(security, "starttls")).toBe("starttls");
    expect(trimmedValues({ a: "  x " })).toEqual({ a: "x" });
  });

  it("lists channels as a sentence", () => {
    expect(orList(["a"])).toBe("a");
    expect(orList(["a", "b"])).toBe("a or b");
    expect(orList(["ntfy", "Telegram", "Email"])).toBe("ntfy, Telegram, or Email");
  });
});

describe("page summaries", () => {
  it("say where each page stands", () => {
    expect(settingsSummary("appearance", DEFAULT_SETTINGS)).toBe("Automatic theme · Comfortable grid");
    expect(settingsSummary("ai", DEFAULT_SETTINGS)).toBe("No AI provider yet");
    expect(settingsSummary("ai", { ...DEFAULT_SETTINGS, llmBaseUrl: "http://x/v1", llmModel: "m" })).toBe("Provider: m");
    expect(settingsSummary("reminders", DEFAULT_SETTINGS)).toBe("Not delivered anywhere yet");
    expect(settingsSummary("reminders", { ...DEFAULT_SETTINGS, notifyValues: { ntfy_url: "https://ntfy.sh/t" } })).toBe("Push");
  });

  it("names the provider by host", () => {
    expect(providerSummary("http://localhost:11434/v1", "llama3")).toBe("llama3 @ localhost:11434");
    expect(providerSummary("not a url", "m")).toBe("m @ not a url");
  });
});

describe("settings layout", () => {
  it("keeps the index beside a page when wide, and shows one at a time on a phone", () => {
    expect(settingsLayout(undefined, true)).toEqual({ index: true, page: "account" });
    expect(settingsLayout("ai", true)).toEqual({ index: true, page: "ai" });
    expect(settingsLayout(undefined, false)).toEqual({ index: true, page: null });
    expect(settingsLayout("ai", false)).toEqual({ index: false, page: "ai" });
  });
});

describe("grid preview", () => {
  it("fits columns to the density inside the width, between 2 and the cap", () => {
    expect(gridPreviewShape("comfortable", "medium")).toEqual({ columns: 5, widthFraction: 1400 / 1920 });
    expect(gridPreviewShape("compact", "full")).toEqual({ columns: 8, widthFraction: 1 });
    expect(gridPreviewShape("spacious", "narrow").columns).toBe(3);
  });
});

describe("wording", () => {
  it("counts things", () => {
    expect(plural(1, "note")).toBe("1 note");
    expect(plural(2, "note")).toBe("2 notes");
    expect(restoredMessage({ notes: 1, attachments: 0, workspaces: 2 })).toBe("Restored 1 note and 0 files across 2 workspaces");
    expect(importedMessage({ notes: 3, attachments: 1 })).toBe("Imported 3 notes and 1 file from Google Keep");
    expect(partialMessage("Stopped", 0, "restored")).toBe("Stopped");
    expect(partialMessage("Stopped", 4, "imported")).toBe("Stopped. 4 notes were imported before it stopped.");
    expect(progressText("Restoring", 2, 5)).toBe("Restoring… 2 of 5");
  });

  it("describes a token by scope and last use", () => {
    const token = { id: "t", name: "n", scope: "write" as const, createdAt: new Date(0), lastUsedAt: null };
    expect(tokenMeta(token, () => "x")).toBe("Read and add · never used");
    expect(tokenMeta({ ...token, scope: "read", lastUsedAt: new Date(0) }, () => "1 Jan")).toBe("Read only · last used 1 Jan");
  });

  it("mints custom task ids in microseconds, like the Dart client", () => {
    expect(customTaskId(1_700_000_000_000)).toBe("custom-1700000000000000");
  });

  it("starts a Keep import in the open workspace when it can", () => {
    const ws = [makeWorkspace({ id: "a", name: "A" }), makeWorkspace({ id: "b", name: "B" })];
    expect(initialKeepWorkspace(ws, "b")).toBe("b");
    expect(initialKeepWorkspace(ws, "zzz")).toBe("a");
    expect(initialKeepWorkspace([], null)).toBeNull();
  });
});
