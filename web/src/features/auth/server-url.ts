import { normalizeBaseUrl } from "@/lib/api/base-url";

// The server picker's rules: how an address reads, and which addresses can be
// saved at all.

/** The address without its scheme or trailing slashes, for display. */
export function displayUrl(url: string): string {
  return url.replace(/^https?:\/\//, "").replace(/\/+$/, "");
}

export type ServerUrlCheck = { readonly ok: true; readonly url: string } | { readonly ok: false; readonly error: string };

const SCHEME_HINT = "Start with http:// or https://, like https://notes.example.com";

/**
 * [input] as a server address to save, or why it is not one. Only http(s)
 * origins with a host are accepted; a path is kept, for a server under a
 * sub-path.
 */
export function checkServerUrl(input: string): ServerUrlCheck {
  const value = normalizeBaseUrl(input);
  if (value === "") {
    return { ok: false, error: "Enter the server's address" };
  }
  if (!/^https?:\/\//i.test(value)) {
    return { ok: false, error: SCHEME_HINT };
  }

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return { ok: false, error: "That doesn't look like a web address" };
  }
  if (parsed.hostname === "") {
    return { ok: false, error: "That doesn't look like a web address" };
  }
  if (parsed.search !== "" || parsed.hash !== "") {
    return { ok: false, error: "Leave out anything after ? or #" };
  }
  return { ok: true, url: normalizeBaseUrl(`${parsed.protocol}//${parsed.host}${parsed.pathname}`) };
}
