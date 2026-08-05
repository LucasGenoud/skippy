/// Browser file plumbing shared by the drop target, the file dialog and the
/// clipboard listener. Web-only: import it from a `dart.library.js_interop`
/// branch, never directly.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/dropped_file.dart';
import '../util/mime.dart';

/// Snapshot a browser [web.FileList] into a Dart list. Must run
/// synchronously inside the event handler, a drop's or paste's DataTransfer
/// is neutered once the handler returns.
List<web.File> webFileHandles(web.FileList? files) => [
  for (var i = 0; i < (files?.length ?? 0); i++)
    if (files!.item(i) case final web.File file) file,
];

/// Read [web.File] handles into in-memory [DroppedFile]s, inferring a mime
/// type from the name when the browser reports none.
Future<List<DroppedFile>> readWebFiles(List<web.File> handles) async {
  final files = <DroppedFile>[];
  for (final handle in handles) {
    final buffer = await handle.arrayBuffer().toDart;
    files.add(
      DroppedFile(
        name: handle.name,
        mime: handle.type.isEmpty ? mimeFromName(handle.name) : handle.type,
        bytes: buffer.toDart.asUint8List(),
      ),
    );
  }
  return files;
}
