import 'package:flutter/foundation.dart';

/// Non-web builds don't have a browser download mechanism; the app is
/// deployed as web, so this is a deliberate no-op kept for API parity.
void downloadTextFile(String filename, String content, String mime) {
  debugPrint('downloadTextFile is web-only (asked for $filename)');
}
