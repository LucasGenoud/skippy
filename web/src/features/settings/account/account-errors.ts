import { ApiError } from "@/lib/api/errors";

const FORBIDDEN = 403;

/** Words for a failed account change: a wrong password reads as one. */
export function accountErrorText(error: unknown, fallback: string): string {
  if (error instanceof ApiError) {
    return error.statusCode === FORBIDDEN ? "Current password is incorrect" : error.serverMessage;
  }
  return fallback;
}

export type AccountField = "name" | "email" | "password";

const MIN_NAME = 2;
const MIN_PASSWORD = 6;

/** The first thing wrong with the form, or null when it can be sent. */
export function validateAccountForm(field: AccountField, value: string, currentPassword: string, confirm: string): string | null {
  const trimmed = value.trim();
  switch (field) {
    case "name":
      return trimmed.length < MIN_NAME ? "Enter your full name" : null;
    case "email":
      if (!trimmed.includes("@")) {
        return "Enter a valid email address";
      }
      return currentPassword === "" ? "Enter your current password" : null;
    case "password":
      if (currentPassword === "") {
        return "Enter your current password";
      }
      if (trimmed.length < MIN_PASSWORD) {
        return "Password must be at least 6 characters";
      }
      return value.trim() !== confirm ? "Passwords don't match" : null;
  }
}
