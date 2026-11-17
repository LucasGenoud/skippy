import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'image_png.dart';

/// Implemented by the iOS, Android and macOS runners.
const _channel = MethodChannel('skippy/clipboard');
const _copyImage = 'copyImage';

/// Whether this device can take a picture onto its clipboard. Windows and
/// Linux have no runner side for it yet, so the control is not offered there.
bool get canCopyImages => switch (defaultTargetPlatform) {
  TargetPlatform.iOS || TargetPlatform.android || TargetPlatform.macOS => true,
  _ => false,
};

/// Fetches the picture at [url] and puts it on the clipboard as a PNG.
/// Answers whether it got there.
Future<bool> copyImageUrl(String url) async {
  if (!canCopyImages) {
    return false;
  }

  final http.Response response;
  try {
    response = await http.get(Uri.parse(url));
  } catch (e) {
    debugPrint('copyImageUrl fetch failed: $e');
    return false;
  }
  if (response.statusCode != 200) {
    return false;
  }

  final png = await encodePng(response.bodyBytes);
  if (png == null) {
    return false;
  }

  try {
    return await _channel.invokeMethod<bool>(_copyImage, png) ?? false;
  } on PlatformException catch (e) {
    debugPrint('copyImageUrl failed: $e');
    return false;
  } on MissingPluginException {
    return false;
  }
}
