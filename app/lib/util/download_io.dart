import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Native (Android/iOS) downloads route through the system share sheet — that's
/// where "Save Image", "Save to Files" and friends live. Mirrors the web
/// build's [downloadTextFile]/[downloadUrl] API so callers never branch on
/// platform. The bytes are written to a temp file first so the OS gets a real
/// file URL with the right extension (which is what makes "Save Image" appear).

void downloadTextFile(String filename, String content, String mime) {
  // Fire-and-forget: the export UI doesn't await the download on any platform.
  _shareBytes(filename, Uint8List.fromList(utf8.encode(content)), mime);
}

Future<void> downloadBytesFile(String filename, Uint8List bytes, String mime) =>
    _shareBytes(filename, bytes, mime);

Future<void> downloadUrl(String url, String filename) async {
  final http.Response response;
  try {
    response = await http.get(Uri.parse(url));
  } catch (e) {
    debugPrint('downloadUrl fetch failed: $e');
    return;
  }
  if (response.statusCode != 200) {
    debugPrint('downloadUrl failed: HTTP ${response.statusCode}');
    return;
  }
  await _shareBytes(
    filename,
    response.bodyBytes,
    response.headers['content-type'],
  );
}

Future<void> _shareBytes(String filename, Uint8List bytes, String? mime) async {
  try {
    final safe = _sanitize(filename);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$safe');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime, name: safe)],
      ),
    );
  } catch (e) {
    debugPrint('share failed for $filename: $e');
  }
}

/// Strip path separators so the name can't escape the temp dir, and fall back
/// to a placeholder when the attachment carries no filename.
String _sanitize(String filename) {
  final cleaned = filename.replaceAll(RegExp(r'[/\\]'), '_').trim();
  return cleaned.isEmpty ? 'download' : cleaned;
}
