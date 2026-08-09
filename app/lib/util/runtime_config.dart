/// Reads runtime configuration the server injected into the page. When the
/// Rust binary serves the web build it can stamp `window.stickyNotesApiBase`
/// into index.html (from the `PUBLIC_URL` env var), letting a
/// self-hoster point the app at a fixed backend without rebuilding it. Off the
/// web there's no injected config, so the stub returns null.
library;

export 'runtime_config_stub.dart'
    if (dart.library.js_interop) 'runtime_config_web.dart';
