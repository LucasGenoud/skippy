/// The path a public share link is served at. Anything under it is handled by
/// the app itself; the backend's static-file fallback already sends unknown
/// paths to `index.html`, so no server route is needed for it.
const String kPublicSharePrefix = '/s/';

/// The share token in a `/s/<token>` URL, or null when [path] is anything
/// else.
///
/// Pure so the one piece of routing this app has can be tested without a
/// browser. Kept deliberately strict: only hex tokens (what the server mints)
/// are accepted, so a stray path can never send someone to a share page that
/// was never going to resolve.
String? publicShareToken(String path) {
  var rest = path;
  final at = rest.indexOf(kPublicSharePrefix);
  // Tolerate a deployment served under a sub-path, where the app sees
  // `/notes/s/<token>`.
  if (at < 0) return null;
  rest = rest.substring(at + kPublicSharePrefix.length);
  // A trailing slash or query is fine; anything with another path segment is
  // not a share URL.
  final end = rest.indexOf(RegExp(r'[/?#]'));
  final token = end < 0 ? rest : rest.substring(0, end);
  if (token.isEmpty) return null;
  final hex = RegExp(r'^[0-9a-fA-F]+$');
  return hex.hasMatch(token) ? token : null;
}
