import 'dart:typed_data';

/// A file the user handed us from outside the app (drag-drop or a picker):
/// name + mime + raw bytes, ready to upload.
class DroppedFile {
  final String name;
  final String mime;
  final Uint8List bytes;

  const DroppedFile({
    required this.name,
    required this.mime,
    required this.bytes,
  });
}
