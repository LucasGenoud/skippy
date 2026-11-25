/// What a way into the app from outside it asked for: a home-screen widget,
/// a Siri or Shortcuts action, a Control Center or Action Button control, a
/// quick-settings tile, or a launcher shortcut.
///
/// All of them arrive as one deep link, so one parser serves every platform:
///
/// ```text
/// skippy://note/<id>?homeWidget=1         open a note
/// skippy://note/<id>?homeWidget=1&add=1   open it on a new checklist row
/// skippy://new?homeWidget=1               new note of the default kind
/// skippy://new?homeWidget=1&kind=<kind>   new note of a given kind
/// ```
///
/// The `homeWidget` flag is required: the plugin that carries these links
/// drops any without it. Native code builds them by hand, so the hosts,
/// parameters and kind names here are a wire contract.
library;

/// The deep link scheme every entry point uses.
const String kLaunchUrlScheme = 'skippy';

/// Query flag on the link behind a widget's "Add item" row.
///
/// Neither platform lets a home-screen widget take text input, so the row
/// opens the note with an empty checklist row already focused instead.
const String kLaunchAddItemParam = 'add';

const String _openNoteHost = 'note';
const String _newNoteHost = 'new';
const String _kindParam = 'kind';

/// The kind of note a launch asked to start.
enum LaunchNoteKind {
  /// The user's default kind, from settings.
  preferred(null),
  checklist('checklist'),

  /// Straight into the recorder, for an audio note.
  voice('voice');

  /// Value of the `kind` parameter; null when the parameter is left out.
  final String? wire;
  const LaunchNoteKind(this.wire);

  /// An unknown kind falls back to the default kind rather than dropping the
  /// launch: whoever asked still wants a note.
  static LaunchNoteKind fromWire(String? value) {
    for (final kind in values) {
      if (kind.wire != null && kind.wire == value) {
        return kind;
      }
    }
    return preferred;
  }
}

sealed class LaunchAction {
  const LaunchAction();

  /// What [uri] asked for, or null when it is not one of our links.
  static LaunchAction? fromUri(Uri? uri) {
    if (uri == null || uri.scheme != kLaunchUrlScheme) {
      return null;
    }

    // skippy://note/<id> parses as host 'note' with one path segment.
    switch (uri.host) {
      case _openNoteHost:
        final segments = uri.pathSegments;
        if (segments.isEmpty || segments.first.isEmpty) {
          return null;
        }
        return OpenNoteAction(
          segments.first,
          addItem: uri.queryParameters[kLaunchAddItemParam] == '1',
        );
      case _newNoteHost:
        return NewNoteAction(
          LaunchNoteKind.fromWire(uri.queryParameters[_kindParam]),
        );
      default:
        return null;
    }
  }
}

/// Show a note, from a widget tap.
final class OpenNoteAction extends LaunchAction {
  final String noteId;

  /// Start a new checklist row in it, from the widget's "Add item" row.
  final bool addItem;

  const OpenNoteAction(this.noteId, {this.addItem = false});
}

/// Start a new note.
final class NewNoteAction extends LaunchAction {
  final LaunchNoteKind kind;

  const NewNoteAction(this.kind);
}
