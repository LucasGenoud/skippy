import 'package:file_picker/file_picker.dart';
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
Future<List<DroppedFile>> pickAnyFiles() async {
  final result = await FilePicker.pickFiles(
    withData: true,
    allowMultiple: true,
  );
  return [
    for (final file in result?.files ?? const <PlatformFile>[])
      if (file.bytes case final bytes?)
        DroppedFile(
          name: file.name,
          mime: mimeFromName(file.name),
          bytes: bytes,
        ),
  ];
}
