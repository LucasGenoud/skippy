"use client";

// Placeholders: the AUTH agent replaces these.
export function LoginScreen() {
  return <div data-placeholder="login" />;
}

export function ResetPasswordScreen({ token }: { token: string }) {
  return <div data-placeholder="reset-password" data-token={token} />;
}
