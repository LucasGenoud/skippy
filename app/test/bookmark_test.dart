import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/link_preview.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/bookmark.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/link_preview.dart';

import 'fake_api.dart';

import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show homeApp, flushTimers;

void main() {
  Bookmark? of(
    String content, {
    String title = '',
    NoteKind kind = NoteKind.text,
  }) => bookmarkOf(serverNote('n', title: title, content: content, kind: kind));

  test('a note that is only a link is a bookmark', () {
    expect(of('https://example.com/a?b=1'), (
      url: 'https://example.com/a?b=1',
      body: '',
    ));
    expect(of('  \nwww.example.com  \n')?.url, 'https://www.example.com');
    expect(of('https://example.com', kind: NoteKind.markdown), isNotNull);
    expect(of('https://example.com', title: 'Read later'), isNotNull);
  });

  test('text under the link stays the bookmark body', () {
    expect(of('https://example.com\n\nA page about examples.'), (
      url: 'https://example.com',
      body: 'A page about examples.',
    ));
  });

  test('anything else is an ordinary note', () {
    expect(of('see https://example.com'), isNull);
    expect(of('https://example.com and more'), isNull);
    expect(of('https://a.com\nhttps://b.com'), isNull);
    expect(of('https://a.com', title: 'from https://b.com'), isNull);
    expect(of('just words'), isNull);
    expect(of(''), isNull);
    expect(of('https://example.com', kind: NoteKind.checklist), isNull);
  });

  test('a note with pictures is not a bookmark', () {
    final note = serverNote('n', content: 'https://example.com');
    final withImage = note.copyWith(
      attachments: [Attachment(id: 'a', mime: 'image/png', url: '/x')],
    );
    expect(bookmarkOf(withImage), isNull);
  });

  testWidgets('a link-only card is a bookmark until it holds more', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeApi()
      ..notes['b1'] = serverNote('b1', content: 'https://example.com')
      ..previews['https://example.com'] = const LinkPreview(
        url: 'https://example.com',
        title: 'Example Domain',
        description: 'For use in examples.',
      );
    final store = NotesStore(api: api, currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    // The app provides the preview cache above every route.
    await tester.pumpWidget(
      Provider(
        create: (_) => LinkPreviewCache(api: api),
        child: homeApp(store),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BookmarkCard), findsOneWidget);
    expect(find.byType(LinkPreviewCard), findsNothing);
    expect(find.text('Example Domain'), findsOneWidget);
    expect(find.text('For use in examples.'), findsOneWidget);
    expect(find.text('https://example.com'), findsNothing);

    store.updateNoteContent('b1', content: 'see https://example.com');
    await tester.pumpAndSettle();

    expect(find.byType(BookmarkCard), findsNothing);
    expect(find.byType(LinkPreviewCard), findsOneWidget);
    await flushTimers(tester);
  });
}
