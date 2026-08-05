import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/dropped_file.dart';
import '../util/mime.dart';
import 'web_files.dart';

bool _installed = false;

/// Files on the clipboard, pulled out of a paste event. `clipboardData.files`
/// covers every current browser; the `items` sweep is the fallback for engines
/// that only expose a pasted image there. Both must be read synchronously,
/// inside the handler.
List<web.File> _clipboardFiles(web.DataTransfer? data) {
  if (data == null) return const [];
  final files = webFileHandles(data.files);
  if (files.isNotEmpty) return files;
  final items = data.items;
  final fromItems = <web.File>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.kind != 'file') continue;
    if (item.getAsFile() case final web.File file) fromItems.add(file);
  }
  return fromItems;
}

/// Browser paste: one document-level listener, installed once, hands whatever
/// files the clipboard carried to [onFiles].
///
/// Registered in the capture phase so it sees the event before the focused
/// field does, and cancels the paste only when there are files AND
/// [wantsFiles] says someone is listening for them — a plain text paste has to
/// reach the engine's hidden input untouched. [wantsFiles] is consulted
/// synchronously because a default action can only be cancelled while the
/// handler runs, and reading file bytes is async.
///
/// Repeat calls are no-ops: every mounted area asks for the listener, and they
/// all pass the same pair of dispatch functions.
void installClipboardPasteListener({
  required bool Function() wantsFiles,
  required void Function(List<DroppedFile> files) onFiles,
}) {
  if (_installed) return;
  _installed = true;

  web.document.addEventListener(
    'paste',
    // toJS only accepts synchronous signatures; do the async reads outside.
    ((web.ClipboardEvent e) {
      final handles = _clipboardFiles(e.clipboardData);
      if (handles.isEmpty || !wantsFiles()) return;
      e.preventDefault();
      Future(() async {
        final files = await readWebFiles(handles);
        onFiles([
          // A copied file keeps its name; a screenshot, which every browser
          // hands over as `image.png`, gets stamped so a run of them stays
          // distinguishable on the note.
          for (final file in files)
            DroppedFile(
              name: pastedFileName(file.mime, suggested: file.name),
              mime: file.mime,
              bytes: file.bytes,
            ),
        ]);
      });
    }).toJS,
    true.toJS,
  );
}
