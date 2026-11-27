part of 'editor_screen.dart';

/// Note links: the `[[` picker while typing, inserting a link, following
/// one, and the links/backlinks panel under the note.
extension _EditorNoteLinks on _EditorScreenState {
  /// Opens the link picker while a `[[` is being typed in the body.
  void _syncLinkQuery() {
    final selection = _contentController.selection;
    final typing =
        _contentFocus.hasFocus &&
        selection.isValid &&
        selection.isCollapsed &&
        (_kind == NoteKind.text || _kind == NoteKind.markdown);
    final query = typing
        ? openLinkQuery(_contentController.text, selection.baseOffset)
        : null;
    if (query == _linkQuery) {
      return;
    }
    _rebuild(() => _linkQuery = query);
  }

  /// Replaces the `[[query` being typed with a link to [target].
  void _insertNoteLink(Note target) {
    final query = _linkQuery;
    if (query == null) {
      return;
    }
    final value = _contentController.value;
    final caret = value.selection.baseOffset;
    final start = caret - query.length - 2;
    final token = noteLinkToken(target.id, noteLinkTitle(target));
    final text = value.text;
    final followedBySpace = caret < text.length && text[caret] == ' ';
    final inserted = followedBySpace ? token : '$token ';
    _contentController.value = TextEditingValue(
      text: text.replaceRange(start, caret, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
    _contentFocus.requestFocus();
  }

  void _openLinkedNote(String id) {
    openNoteEditor(
      context,
      noteId: id,
      openFullscreen: () => Navigator.of(context).push(
        NoteZoomRoute(
          settings: RouteSettings(name: noteRouteName(id)),
          builder: (_) => EditorScreen(noteId: id),
        ),
      ),
    );
  }

  /// The notes [note] links to and the notes linking to it; null when there
  /// are neither.
  Widget? _linksSection(Note? note) {
    if (note == null) {
      return null;
    }
    final seen = <String>{};
    final outgoing = [
      for (final link in findNoteLinks(note.content))
        if (link.noteId != note.id && seen.add(link.noteId))
          switch (_store.linkTitleFor(link.noteId)) {
            final String title => LinkedNoteRef(
              id: link.noteId,
              title: title,
              reachable: true,
            ),
            null => LinkedNoteRef(
              id: link.noteId,
              title: link.title,
              reachable: false,
            ),
          },
    ];
    final incoming = [
      for (final source in _backlinksTo(note.id))
        LinkedNoteRef(
          id: source.id,
          title: noteLinkTitle(source),
          reachable: true,
        ),
    ];
    if (outgoing.isEmpty && incoming.isEmpty) {
      return null;
    }
    return NoteLinksSection(
      outgoing: outgoing,
      incoming: incoming,
      onOpen: _openLinkedNote,
    );
  }
}
