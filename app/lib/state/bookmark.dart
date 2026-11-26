import '../models/note.dart';
import '../util/linkify.dart';

/// A note shown as a bookmark: the link it saves and whatever was written
/// under it.
typedef Bookmark = ({String url, String body});

/// The bookmark a note reads as, or null when it is an ordinary note.
///
/// A bookmark is not a stored kind but a way of showing a text or markdown
/// note whose first line is a lone link and whose only link that is. Pasting
/// a link therefore makes one, and writing a second link, or anything before
/// the first, makes it a note again, with nothing to convert or sync. Text
/// under the link, such as a server-written page summary, stays the
/// bookmark's body rather than undoing it.
Bookmark? bookmarkOf(Note note) {
  if (note.kind != NoteKind.text && note.kind != NoteKind.markdown) {
    return null;
  }
  // Pictures make it a photo note with a link, not a bookmark.
  if (note.attachments.isNotEmpty || findUrls(note.title).isNotEmpty) {
    return null;
  }

  final content = note.content.trim();
  final urls = findUrls(content);
  if (urls.length != 1) {
    return null;
  }
  final link = urls.single;
  final lineEnd = content.indexOf('\n');
  final firstLineEnd = lineEnd < 0 ? content.length : lineEnd;
  if (link.start != 0 ||
      content.substring(0, firstLineEnd).trim().length != link.end) {
    return null;
  }
  return (url: link.url, body: content.substring(firstLineEnd).trim());
}
