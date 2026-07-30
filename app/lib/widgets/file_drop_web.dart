import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:web/web.dart' as web;

import '../models/dropped_file.dart';
import '../util/mime.dart';

/// Snapshot a browser [web.FileList] into a Dart list. Must run
/// synchronously inside the event handler, a drop's DataTransfer is
/// neutered once the handler returns.
List<web.File> _fileHandles(web.FileList? files) => [
  for (var i = 0; i < (files?.length ?? 0); i++)
    if (files!.item(i) case final web.File file) file,
];

/// Read [web.File] handles into in-memory [DroppedFile]s, inferring a mime
/// type from the name when the browser reports none.
Future<List<DroppedFile>> _readFiles(List<web.File> handles) async {
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

/// Browser file dialog via a bare `<input type=file>`. Empty list on cancel.
///
/// Deliberately not file_picker: its web cancel detection treats a window
/// focus event as "dialog dismissed" and swallows any selection that takes
/// longer than a second, which on Firefox is every real pick. The
/// standardized `cancel` event (Firefox 91+/Chrome 113+) is all we need.
Future<List<DroppedFile>> pickAnyFiles() {
  final completer = Completer<List<DroppedFile>>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true;
  input.style.display = 'none';
  // Keep the input attached until the dialog resolves; some browsers drop
  // the change event for detached inputs.
  web.document.body!.appendChild(input);

  input.addEventListener(
    'change',
    // toJS only accepts synchronous signatures; do the async reads inside.
    ((web.Event _) {
      final handles = _fileHandles(input.files);
      input.remove();
      Future(() async {
        final picked = await _readFiles(handles);
        if (!completer.isCompleted) completer.complete(picked);
      });
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      input.remove();
      if (!completer.isCompleted) completer.complete(const []);
    }).toJS,
  );

  input.click();
  return completer.future;
}

/// Web drop target: makes its subtree accept files dragged in from the OS.
///
/// Flutter web renders to a canvas, so drops can only be observed at the
/// document level. All mounted areas share one set of document listeners and
/// a stack decides who receives the drop: the most recently mounted area
/// whose route is current (the editor pushed over home wins; an area under
/// an unrelated route, e.g. settings, is skipped).
class FileDropArea extends StatefulWidget {
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
  State<FileDropArea> createState() => _FileDropAreaState();
}

class _FileDropAreaState extends State<FileDropArea> {
  static final List<_FileDropAreaState> _stack = [];
  static bool _listenersInstalled = false;

  /// dragenter/dragleave fire for every element boundary crossed; the
  /// counter nets them out so we only clear the overlay on leaving the page.
  static int _dragDepth = 0;

  static _FileDropAreaState? get _target {
    for (final state in _stack.reversed) {
      if (state._isActive) return state;
    }
    return null;
  }

  bool _dragging = false;

  bool get _isActive => mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    _stack.add(this);
    _installListeners();
  }

  @override
  void dispose() {
    _stack.remove(this);
    super.dispose();
  }

  static void _installListeners() {
    if (_listenersInstalled) return;
    _listenersInstalled = true;

    bool hasFiles(web.DragEvent e) {
      final dt = e.dataTransfer;
      if (dt == null) return false;
      final types = dt.types.toDart;
      return types.any((t) => t.toDart == 'Files');
    }

    void setDragging(bool value) {
      for (final state in _stack) {
        state._showOverlay(value && identical(state, _target));
      }
    }

    web.document.addEventListener(
      'dragenter',
      ((web.DragEvent e) {
        if (!hasFiles(e)) return;
        e.preventDefault();
        _dragDepth++;
        setDragging(true);
      }).toJS,
    );
    web.document.addEventListener(
      'dragover',
      ((web.DragEvent e) {
        if (!hasFiles(e)) return;
        // preventDefault is what makes the page a valid drop target.
        e.preventDefault();
        e.dataTransfer?.dropEffect = 'copy';
      }).toJS,
    );
    web.document.addEventListener(
      'dragleave',
      ((web.DragEvent e) {
        if (!hasFiles(e)) return;
        if (_dragDepth > 0) _dragDepth--;
        if (_dragDepth == 0) setDragging(false);
      }).toJS,
    );
    web.document.addEventListener(
      'drop',
      ((web.DragEvent e) {
        if (!hasFiles(e)) return;
        e.preventDefault();
        _dragDepth = 0;
        final target = _target;
        setDragging(false);
        if (target == null) return;
        target._receive(_fileHandles(e.dataTransfer!.files));
      }).toJS,
    );
  }

  void _showOverlay(bool value) {
    if (_dragging == value || !mounted) return;
    setState(() => _dragging = value);
  }

  Future<void> _receive(List<web.File> handles) async {
    final files = await _readFiles(handles);
    if (files.isEmpty || !mounted) return;
    await widget.onFiles(files);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        widget.child,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.black.withValues(alpha: 0.35),
                alignment: Alignment.center,
                child: Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(kRadius),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 18,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_upload_outlined, color: scheme.primary),
                        const SizedBox(width: 12),
                        Text(
                          widget.hint,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
