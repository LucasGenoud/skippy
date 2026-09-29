import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_links.dart';

const _a = '11111111-1111-4111-8111-111111111111';
const _b = '22222222-2222-4222-8222-222222222222';

Note _note(String id, {String title = '', String content = ''}) => Note(
  id: id,
  workspaceId: 'w',
  kind: NoteKind.text,
  title: title,
  content: content,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  group('findNoteLinks', () {
    test('reads the id and title of every link', () {
      final text = 'see [[$_a|Groceries]] and [[$_b|Trip]]';
      final links = findNoteLinks(text);

      expect(links.map((l) => l.noteId), [_a, _b]);
      expect(links.map((l) => l.title), ['Groceries', 'Trip']);
      expect(text.substring(links[0].start, links[0].end), '[[$_a|Groceries]]');
      expect(
        text.substring(links[0].titleStart, links[0].titleEnd),
        'Groceries',
      );
    });

    test('ignores brackets that are not a link', () {
      expect(findNoteLinks('[[Groceries]] [[nope|x]] [x](y)'), isEmpty);
    });
  });

  test('noteLinkToken keeps the token parseable whatever the title', () {
    final token = noteLinkToken(_a, 'a [b] | c\nd');
    final links = findNoteLinks(token);

    expect(links.single.noteId, _a);
    expect(links.single.title, 'a b c d');
    expect(noteLinkToken(_a, '  '), '[[$_a|Untitled note]]');
  });

  test('plainNoteLinks shows each link as its title', () {
    expect(
      plainNoteLinks('see [[$_a|Old]] now', titleFor: (id) => 'New'),
      'see New now',
    );
    expect(plainNoteLinks('see [[$_a|Old]] now'), 'see Old now');
  });

  test('markdownNoteLinks turns links into tappable markdown links', () {
    final markdown = markdownNoteLinks('see [[$_a|Old]]');

    expect(markdown, 'see [Old]($kNoteLinkScheme:$_a)');
    expect(noteIdFromHref('$kNoteLinkScheme:$_a'), _a);
    expect(noteIdFromHref('https://example.com'), isNull);
  });

  test('remapNoteLinks follows copied notes and leaves the rest', () {
    const copy = '33333333-3333-4333-8333-333333333333';
    final text = '[[$_a|A]] [[$_b|B]]';

    expect(remapNoteLinks(text, {_a: copy}), '[[$copy|A]] [[$_b|B]]');
  });

  group('openLinkQuery', () {
    test('is the text typed after an unclosed [[', () {
      expect(openLinkQuery('go to [[gro', 11), 'gro');
      expect(openLinkQuery('go to [[', 8), '');
    });

    test('is null once the link is closed or the line ends', () {
      const closed = '[[$_a|A]] x';
      expect(openLinkQuery(closed, closed.length), isNull);
      expect(openLinkQuery('[[gro\nceries', 12), isNull);
      expect(openLinkQuery('no link', 7), isNull);
    });
  });

  test('backlinksTo lists the notes linking to a note', () {
    final notes = [
      _note(_a, title: 'A'),
      _note(_b, title: 'B', content: 'see [[$_a|A]]'),
      _note('c', title: 'C', content: 'nothing'),
    ];

    expect(backlinksTo(_a, notes).map((n) => n.id), [_b]);
    expect(backlinksTo(_b, notes), isEmpty);
  });

  test('linkCandidates matches titles and content, recent first', () {
    final old = _note(_a, title: 'Grocery list');
    final recent = Note(
      id: _b,
      workspaceId: 'w',
      kind: NoteKind.text,
      title: '',
      content: 'buy groceries',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 2),
    );

    expect(linkCandidates([old, recent], 'groc').map((n) => n.id), [_b, _a]);
    expect(linkCandidates([old, recent], 'groc', excludeId: _b).length, 1);
  });

  group('atomic links', () {
    final text = 'x [[$_a|A]] y';
    final link = findNoteLinks(text).single;

    test('a caret inside a link snaps to the edge it moved toward', () {
      expect(
        snapOutOfLinks(text, link.start + 3, previous: link.start),
        link.end,
      );
      expect(
        snapOutOfLinks(text, link.end - 1, previous: link.end),
        link.start,
      );
      expect(snapOutOfLinks(text, 1, previous: 0), 1);
    });

    test('deleting part of a link deletes all of it', () {
      final before = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: link.end),
      );
      final after = TextEditingValue(
        text: text.replaceRange(link.end - 1, link.end, ''),
        selection: TextSelection.collapsed(offset: link.end - 1),
      );

      final fixed = const NoteLinkFormatter().formatEditUpdate(before, after);

      expect(fixed.text, 'x  y');
      expect(fixed.selection, const TextSelection.collapsed(offset: 2));
    });

    test('ordinary typing passes through', () {
      const before = TextEditingValue(text: 'ab');
      const after = TextEditingValue(text: 'abc');

      expect(const NoteLinkFormatter().formatEditUpdate(before, after), after);
    });
  });
}
