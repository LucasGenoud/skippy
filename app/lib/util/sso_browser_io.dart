import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// The scheme the server sends a native sign-in back on. Must match
/// `oidc::APP_SCHEME` on the server and the Android callback activity.
const _scheme = 'skippy-auth';

/// Whether starting a sign-in navigates this page away (web only).
const ssoLeavesPage = false;

/// Where the server should send the result.
String ssoReturnTo() => '$_scheme://callback';

/// Run the sign-in at [start] and return the URL it came back on, or null
/// when the person closed the browser.
Future<Uri?> runSsoBrowser(Uri start) async {
  try {
    final result = await FlutterWebAuth2.authenticate(
      url: start.toString(),
      callbackUrlScheme: _scheme,
    );
    return Uri.parse(result);
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') return null;
    rethrow;
  }
}

/// The sign-in result this launch was opened with (web only).
Uri? takeSsoReturn() => null;
