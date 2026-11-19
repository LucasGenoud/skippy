/// The browser half of single sign-on. Native apps open the provider in a
/// system auth session and get the result back on the `skippy-auth` scheme;
/// the web app navigates away and is reloaded at `/sso` with the result.
library;

export 'sso_browser_io.dart'
    if (dart.library.js_interop) 'sso_browser_web.dart';
