// The two URLs the app answers when someone arrives from a link: a public
// share page and a password reset form. Ported from `util/public_route.dart`.

export const PUBLIC_SHARE_PREFIX = "/s/";
/** Kept in step with `RESET_PATH` in the backend's `handlers/auth.rs`. */
export const PASSWORD_RESET_PREFIX = "/reset/";

const HEX = /^[0-9a-fA-F]+$/;

/** The hex token in a `<prefix><token>` path (sub-path prefix tolerated). */
function linkToken(path: string, prefix: string): string | null {
  const at = path.indexOf(prefix);
  if (at < 0) {
    return null;
  }
  const rest = path.slice(at + prefix.length);
  const end = rest.search(/[/?#]/);
  const token = end < 0 ? rest : rest.slice(0, end);
  if (!token) {
    return null;
  }
  return HEX.test(token) ? token : null;
}

export const publicShareToken = (path: string): string | null => linkToken(path, PUBLIC_SHARE_PREFIX);
export const passwordResetToken = (path: string): string | null => linkToken(path, PASSWORD_RESET_PREFIX);
