import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Native downloads take one of two shapes, both mirroring the web build's
/// [downloadTextFile]/[downloadBytesFile]/[downloadUrl] API so callers never
/// branch on platform.
///
/// On a phone they route through the system share sheet, because that is where
/// "Save Image" and "Save to Files" live and there is no folder for the user to
/// aim at. On a desktop there is a real filesystem in front of them, so they
/// get the ordinary save dialog every other desktop app shows; a share sheet
/// there would be a detour on macOS and has no dependable file target at all on
/// Windows.

bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

void downloadTextFile(String filename, String content, String mime) {
  // Fire-and-forget: the export UI doesn't await the download on any platform.
  _save(filename, Uint8List.fromList(utf8.encode(content)), mime);
}

Future<void> downloadBytesFile(String filename, Uint8List bytes, String mime) =>
    _save(filename, bytes, mime);

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
  await _save(filename, response.bodyBytes, response.headers['content-type']);
}

Future<void> _save(String filename, Uint8List bytes, String? mime) => _isDesktop
    ? _saveToChosenFile(filename, bytes, mime)
    : _shareBytes(filename, bytes, mime);

/// Desktop: ask where to put it, and let the picker write the bytes. A null
/// URI means the user dismissed the dialog, which is not an error.
Future<void> _saveToChosenFile(
  String filename,
  Uint8List bytes,
  String? mime,
) async {
  final safe = _sanitize(filename);
  try {
    await FilePicker.saveFile(
      dialogTitle: 'Save $safe',
      fileName: safe,
      bytes: bytes,
      mimeType: _bareMime(mime),
      windowsOptions: const WindowsOptions(lockParentWindow: true),
      linuxOptions: const LinuxOptions(lockParentWindow: true),
    );
  } catch (e) {
    debugPrint('save dialog failed for $filename: $e');
  }
}

/// The save dialog wants a bare type, but a `mime` taken off a Content-Type
/// header can carry parameters (`text/plain; charset=utf-8`). Drop them, and
/// fall back to the generic type when there is nothing usable left.
String _bareMime(String? mime) {
  final bare = (mime ?? '').split(';').first.trim();
  return bare.isEmpty ? 'application/octet-stream' : bare;
}

/// Mobile: the bytes are written to a temp file first so the OS gets a real
/// file URL with the right extension, which is what makes "Save Image" appear.
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
