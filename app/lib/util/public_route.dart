/// The URLs this app answers at when someone arrives from a link rather than
/// from the app itself: a public share page and a password reset form. Both
/// are handled by the app; the backend's static-file fallback already sends
/// unknown paths to `index.html`, so neither needs a server route.
library;

/// The path a public share link is served at.
const String kPublicSharePrefix = '/s/';

/// The path an emailed password reset link is served at. Kept in step with
/// `RESET_PATH` in the backend's `handlers/auth.rs`, which writes the links.
const String kPasswordResetPrefix = '/reset/';

/// The token in a `<prefix><token>` URL, or null when [path] is anything else.
///
/// Pure so the little routing this app has can be tested without a browser.
/// Kept deliberately strict: only hex tokens (what the server mints) are
/// accepted, so a stray path can never send someone to a page that was never
/// going to resolve.
String? _linkToken(String path, String prefix) {
  var rest = path;
  final at = rest.indexOf(prefix);
  // Tolerate a deployment served under a sub-path, where the app sees
  // `/notes/s/<token>`.
  if (at < 0) return null;
  rest = rest.substring(at + prefix.length);
  // A trailing slash or query is fine; anything with another path segment is
  // not one of these URLs.
  final end = rest.indexOf(RegExp(r'[/?#]'));
  final token = end < 0 ? rest : rest.substring(0, end);
  if (token.isEmpty) return null;
  final hex = RegExp(r'^[0-9a-fA-F]+$');
  return hex.hasMatch(token) ? token : null;
}

/// The share token in a `/s/<token>` URL, or null when [path] is anything
/// else.
String? publicShareToken(String path) => _linkToken(path, kPublicSharePrefix);

/// The reset token in a `/reset/<token>` URL, or null when [path] is anything
/// else.
String? passwordResetToken(String path) =>
    _linkToken(path, kPasswordResetPrefix);
