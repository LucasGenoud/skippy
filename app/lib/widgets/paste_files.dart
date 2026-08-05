import 'package:flutter/material.dart';

import '../models/dropped_file.dart';
import '../util/mime.dart';
import '../util/snack.dart';
import 'paste_events.dart';

/// Rich content the Android keyboard can hand a field. Kept to the image
/// types the note surfaces render inline; anything else the keyboard offers
/// is declined rather than attached as an opaque blob.
const List<String> _insertableMimeTypes = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
];

/// Turn keyboard-inserted rich content into an uploadable file, or null when
/// the platform handed over a reference it couldn't read (the engine leaves
/// [KeyboardInsertedContent.data] null when fetching the content URI failed).
DroppedFile? pastedContentFile(
  KeyboardInsertedContent content, {
  DateTime? at,
}) {
  final data = content.data;
  if (data == null || data.isEmpty) return null;
  return DroppedFile(
    name: pastedFileName(content.mimeType, at: at),
    mime: content.mimeType,
    bytes: data,
  );
}

/// Makes its subtree the destination for files on the clipboard: paste a
/// screenshot and it lands on the note as an image, paste a file and it
/// becomes an attachment.
///
/// Two paths feed it, because the platforms deliver a paste differently:
///
///  * On the web the browser fires a document-level paste event carrying the
///    files, whatever is focused. All mounted areas share one listener and a
///    stack decides who receives it: the most recently mounted area that is
///    [enabled] and whose route is current, so the open editor wins over the
///    quick-add composer behind it. Same routing as `FileDropArea`.
///  * On Android the clipboard reaches the app through the focused field, so
///    fields opt in with `contentInsertionConfiguration: insertionOf(context)`
///    and Gboard's clipboard panel commits the image straight to this area.
///
/// Pasted text is never touched; only files are intercepted.
class PasteFileArea extends StatefulWidget {
  /// Whether this area currently wants pastes. The quick-add composer only
  /// does while it is open; a note in Trash never does.
  final bool enabled;
  final Future<void> Function(List<DroppedFile> files) onFiles;
  final Widget child;

  const PasteFileArea({
    super.key,
    this.enabled = true,
    required this.onFiles,
    required this.child,
  });

  /// The configuration a text field inside a [PasteFileArea] needs so that
  /// content committed by the keyboard reaches the area. Null outside one, in
  /// which case the field keeps Flutter's default (no rich content).
  static ContentInsertionConfiguration? insertionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PasteFileScope>()?.insertion;

  @override
  State<PasteFileArea> createState() => _PasteFileAreaState();
}

class _PasteFileAreaState extends State<PasteFileArea> {
  static final List<_PasteFileAreaState> _stack = [];

  static _PasteFileAreaState? get _target {
    for (final state in _stack.reversed) {
      if (state._isActive) return state;
    }
    return null;
  }

  bool get _isActive =>
      mounted && widget.enabled && (ModalRoute.of(context)?.isCurrent ?? true);

  late final ContentInsertionConfiguration _insertion;

  @override
  void initState() {
    super.initState();
    _stack.add(this);
    // Held across rebuilds so the fields reading it don't rebuild every frame.
    _insertion = ContentInsertionConfiguration(
      allowedMimeTypes: _insertableMimeTypes,
      onContentInserted: _receiveInserted,
    );
    installClipboardPasteListener(wantsFiles: _hasTarget, onFiles: _dispatch);
  }

  @override
  void dispose() {
    _stack.remove(this);
    super.dispose();
  }

  static bool _hasTarget() => _target != null;

  static void _dispatch(List<DroppedFile> files) {
    if (files.isEmpty) return;
    _target?.widget.onFiles(files);
  }

  void _receiveInserted(KeyboardInsertedContent content) {
    if (!widget.enabled) return;
    final file = pastedContentFile(content);
    if (file == null) {
      showAppSnack(
        "Couldn't read the pasted image",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
      return;
    }
    widget.onFiles([file]);
  }

  @override
  Widget build(BuildContext context) =>
      _PasteFileScope(insertion: _insertion, child: widget.child);
}

class _PasteFileScope extends InheritedWidget {
  final ContentInsertionConfiguration insertion;

  const _PasteFileScope({required this.insertion, required super.child});

  @override
  bool updateShouldNotify(_PasteFileScope oldWidget) =>
      insertion != oldWidget.insertion;
}
