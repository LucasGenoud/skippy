import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Pure classification of an OS share payload into what kind of note it becomes.
/// Kept free of `dart:io` and any platform channel so it is unit-testable with
/// plain [SharedMediaFile] values; the actual file reading + note creation live
/// in the mobile-only intake service.
sealed class SharePayload {}

/// The user shared plain text and/or link(s): one text note holding the joined
/// content. Shared links render the existing unfurl preview strip for free.
class SharedTextPayload extends SharePayload {
  final String text;
  SharedTextPayload(this.text);
}

/// The user shared media/files: one note holding them all as attachments.
class SharedFilesPayload extends SharePayload {
  final List<SharedMediaFile> files;
  SharedFilesPayload(this.files);
}

/// Decide what note (if any) a share payload should become.
///
/// If anything file-like is present (image/video/file) it wins and becomes an
/// attachment note; a payload of only text/url becomes a text note. Returns
/// null when there is nothing usable (empty payload, blank text).
SharePayload? classifyShare(List<SharedMediaFile> media) {
  if (media.isEmpty) return null;

  final files = media
      .where(
        (m) =>
            m.type != SharedMediaType.text && m.type != SharedMediaType.url,
      )
      .toList();
  if (files.isNotEmpty) return SharedFilesPayload(files);

  final text = media
      .map((m) => m.path.trim())
      .where((s) => s.isNotEmpty)
      .join('\n');
  return text.isEmpty ? null : SharedTextPayload(text);
}
