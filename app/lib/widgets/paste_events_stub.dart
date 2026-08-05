import '../models/dropped_file.dart';

/// Non-web builds have no document to listen on: a paste is delivered by the
/// platform straight to the focused field, so there is nothing to install.
/// Keep the API identical to the web version.
void installClipboardPasteListener({
  required bool Function() wantsFiles,
  required void Function(List<DroppedFile> files) onFiles,
}) {}
