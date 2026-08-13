import 'dart:convert';

import 'package:file_picker/file_picker.dart';
// file_picker keeps the platform interface out of its public library, so
// standing a fake in front of the save dialog has to reach into src/.
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/download.dart';

/// Exports and attachment downloads go to a save dialog on a desktop, where
/// there is a filesystem to aim at, and to the share sheet on a phone, where
/// there isn't. These pin the branch: a desktop must never quietly fall back
/// to the share sheet, which has no dependable file target on Windows.
class _RecordingFilePicker extends FilePickerPlatform {
  int calls = 0;
  String? fileName;
  Uint8List? bytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls++;
    this.fileName = fileName;
    this.bytes = bytes;
    return '/tmp/$fileName';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingFilePicker picker;

  setUp(() {
    picker = _RecordingFilePicker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a desktop export goes through the save dialog, with the bytes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await downloadBytesFile(
      'skippy-2026-08-13.zip',
      Uint8List.fromList([1, 2, 3, 4]),
      'application/zip',
    );

    expect(picker.calls, 1);
    expect(picker.fileName, 'skippy-2026-08-13.zip');
    expect(picker.bytes, [1, 2, 3, 4]);
  });

  test('Windows gets the same dialog, not the share sheet', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await downloadBytesFile(
      'notes.json',
      Uint8List.fromList(utf8.encode('[]')),
      'application/json',
    );

    expect(picker.calls, 1);
    expect(picker.fileName, 'notes.json');
  });

  test('a phone keeps the share sheet', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    // No plugins are registered under test, so the share path fails inside its
    // own guard. What matters is that it never reached the save dialog.
    await downloadBytesFile(
      'notes.json',
      Uint8List.fromList(utf8.encode('[]')),
      'application/json',
    );

    expect(picker.calls, 0);
  });

  test('a name that could escape its folder is flattened first', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await downloadBytesFile(
      '../../etc/passwd',
      Uint8List.fromList([0]),
      'application/octet-stream',
    );

    expect(picker.fileName, '.._.._etc_passwd');
  });
}
