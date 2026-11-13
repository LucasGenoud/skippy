// The checks the sign-in, create-account and reset forms run before calling
// the server. Ported from `screens/login_screen.dart` and
// `screens/reset_password_screen.dart`; pure so the rules are testable.

/** The server's own floor (`handlers/auth.rs`); checked here to save a round trip. */
export const MIN_PASSWORD_LENGTH = 6;

export type LoginMode = "signIn" | "create";

export type LoginField = "name" | "email" | "password" | "confirm";

export interface LoginInput {
  readonly name: string;
  readonly email: string;
  readonly password: string;
  readonly confirm: string;
}

/** Inline errors per field; an empty object means the form may be sent. */
export type FieldErrors = Partial<Record<LoginField, string>>;

const FIELD_ORDER: readonly LoginField[] = ["name", "email", "password", "confirm"];

/**
 * What is wrong with the form, presence first: every empty field is flagged at
 * once, and only a complete form goes on to the password rules.
 */
export function validateLogin(mode: LoginMode, input: LoginInput): FieldErrors {
  const creating = mode === "create";
  const errors: FieldErrors = {};
  if (creating && input.name.trim() === "") {
    errors.name = "Enter your name";
  }
  if (input.email.trim() === "") {
    errors.email = "Enter your email";
  }
  if (input.password === "") {
    errors.password = "Enter your password";
  }
  if (Object.keys(errors).length > 0 || !creating) {
    return errors;
  }

  if (input.password.length < MIN_PASSWORD_LENGTH) {
    return { password: `Use at least ${MIN_PASSWORD_LENGTH} characters` };
  }
  if (input.password !== input.confirm) {
    return { confirm: "Passwords don't match" };
  }
  return {};
}

/** The first field with an error, which takes focus. */
export function firstInvalidField(errors: FieldErrors): LoginField | null {
  return FIELD_ORDER.find((field) => errors[field] !== undefined) ?? null;
}

/** Where Enter in [field] goes: the next field, or "submit". */
export function nextOnEnter(mode: LoginMode, field: LoginField): LoginField | "submit" {
  switch (field) {
    case "name":
      return "email";
    case "email":
      return "password";
    case "password":
      return mode === "create" ? "confirm" : "submit";
    case "confirm":
      return "submit";
  }
}

export type ResetField = "password" | "confirm";

/** The reset form's checks: a password at the server's floor, typed twice. */
export function validateReset(password: string, confirm: string): Partial<Record<ResetField, string>> {
  if (password === "") {
    return { password: "Choose a password" };
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    return { password: `Use at least ${MIN_PASSWORD_LENGTH} characters` };
  }
  if (password !== confirm) {
    return { confirm: "Passwords don't match" };
  }
  return {};
}
