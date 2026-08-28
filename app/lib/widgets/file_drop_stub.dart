import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/dropped_file.dart';
import '../util/mime.dart';

/// Non-web builds: OS drag-and-drop isn't wired up, so this is just a
/// passthrough. Keep the API identical to the web version.
class FileDropArea extends StatelessWidget {
  final String hint;
  final Future<void> Function(List<DroppedFile> files) onFiles;
  final Widget child;

  const FileDropArea({
    super.key,
    required this.hint,
    required this.onFiles,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => child;
}

/// Native file dialog via file_picker. Empty list on cancel.
///
/// The picker hands back handles, not bytes, so each selection is read here.
/// A file that won't read is dropped rather than thrown, so one unreadable
/// pick out of several doesn't lose the rest of the selection.
Future<List<DroppedFile>> pickAnyFiles() async {
  final picked = await FilePicker.pickFiles();
  final files = <DroppedFile>[];
  for (final file in picked) {
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      debugPrint('could not read picked file ${file.name}: $e');
      continue;
    }
    files.add(
      DroppedFile(name: file.name, mime: mimeFromName(file.name), bytes: bytes),
    );
  }
  return files;
}
