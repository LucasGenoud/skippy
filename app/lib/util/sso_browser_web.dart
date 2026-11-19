import 'package:web/web.dart' as web;

/// The app path the server sends a web sign-in back to. Anything under it
/// reaches `index.html` through the server's static-file fallback.
const _returnPath = '/sso';

/// Whether starting a sign-in navigates this page away (web only).
const ssoLeavesPage = true;

/// Where the server should send the result.
String ssoReturnTo() => '${Uri.base.origin}$_returnPath';

/// Leave for the provider. The page is reloaded at [ssoReturnTo] afterwards,
/// so this never completes with a result.
Future<Uri?> runSsoBrowser(Uri start) async {
  web.window.location.assign(start.toString());
  return null;
}

/// The sign-in result this page was loaded with, if any. Taken once: the
/// address bar is put back to `/` so a reload or a bookmark does not replay
/// a spent code.
Uri? takeSsoReturn() {
  final here = Uri.base;
  if (here.path != _returnPath) return null;
  // Keep the entry's state: the engine's router stores its own there.
  web.window.history.replaceState(web.window.history.state, '', '/');
  return here;
}
