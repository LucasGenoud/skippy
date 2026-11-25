import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/link_preview.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/widgets/link_preview.dart';
import 'package:skippy/widgets/linked_text.dart';

import 'fake_api.dart';
import 'finders.dart';

void main() {
  group('LinkedText', () {
    testWidgets('long-pressing a URL keeps the enclosing gesture behavior', (
      tester,
    ) async {
      var longPressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              onLongPress: () => longPressed = true,
              child: const LinkedText(text: 'https://example.com'),
            ),
          ),
        ),
      );

      await tester.longPress(find.byType(LinkedText));
      await tester.pump();
      expect(longPressed, isTrue);
    });

    testWidgets('renders plain text when there are no links', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LinkedText(text: 'just some words')),
        ),
      );
      expect(find.text('just some words'), findsOneWidget);
    });
  });

  group('LinkPreviewCard', () {
    // Equal data: images share one cache entry, so an image left decoding in
    // one test must not be what the next one finds.
    tearDown(() {
      imageCache
        ..clear()
        ..clearLiveImages();
    });

    Widget harness(FakeApi api, Widget child) => MaterialApp(
      home: Scaffold(
        body: Provider<LinkPreviewCache>.value(
          value: LinkPreviewCache(api: api),
          child: child,
        ),
      ),
    );

    testWidgets('shows the site name and title and opens on tap', (
      tester,
    ) async {
      final api = FakeApi();
      api.previews['https://youtube.com'] = const LinkPreview(
        url: 'https://youtube.com',
        title: 'YouTube',
        siteName: 'YouTube',
        // With an image the card renders through the IntrinsicHeight/stretch
        // Row path (the thumbnail); the network image fails in tests and falls
        // back to the favicon box, still exercising the layout.
        image: 'https://cdn.example/logo.png',
      );
      final opened = <String>[];

      await tester.pumpWidget(
        harness(
          api,
          LinkPreviewCard(url: 'https://youtube.com', onOpen: opened.add),
        ),
      );
      await tester.pumpAndSettle();

      // Title + site-name caption both render.
      expect(find.text('YouTube'), findsNWidgets(2));

      await tester.tap(find.byType(LinkPreviewCard));
      await tester.pump();
      expect(opened, ['https://youtube.com']);
    });

    testWidgets('falls back to a host chip with no metadata', (tester) async {
      final api = FakeApi(); // no canned preview → unfurl returns null
      await tester.pumpWidget(
        harness(api, const LinkPreviewCard(url: 'https://example.com/x')),
      );
      await tester.pumpAndSettle();
      // The chip shows the bare host.
      expect(find.text('example.com'), findsOneWidget);
    });

    testWidgets('offers summarizing only when a callback is provided', (
      tester,
    ) async {
      final api = FakeApi();
      final summarized = <String>[];
      final opened = <String>[];
      await tester.pumpWidget(
        harness(
          api,
          LinkPreviewCard(
            url: 'https://example.com/article',
            onOpen: opened.add,
            onSummarize: (url) async => summarized.add(url),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(findAction('Summarize page'));
      await tester.pump();
      expect(summarized, ['https://example.com/article']);
      expect(opened, isEmpty);
    });

    // The server inlines small favicons as `data:` URIs so Flutter web can
    // render them (a cross-origin favicon is CORS-tainted on CanvasKit). Those
    // must decode to bytes, mobile's NetworkImage can't fetch the data: scheme.
    testWidgets('renders an inlined data: favicon via MemoryImage', (
      tester,
    ) async {
      // A valid 1x1 transparent PNG.
      const dataUri =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFc'
          'SJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      final api = FakeApi();
      api.previews['https://flutter.dev'] = const LinkPreview(
        url: 'https://flutter.dev',
        title: 'Flutter',
        siteName: 'flutter.dev',
        favicon: dataUri,
      );
      await tester.pumpWidget(
        harness(api, const LinkPreviewCard(url: 'https://flutter.dev')),
      );
      await tester.pumpAndSettle();

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(
        images.any((i) => i.image is MemoryImage),
        isTrue,
        reason: 'a data: favicon must be decoded to bytes, not fetched',
      );
      // A valid inlined icon means no globe fallback.
      expect(find.byIcon(Icons.public), findsNothing);
    });

    testWidgets('renders an inlined data: Open Graph image via MemoryImage', (
      tester,
    ) async {
      const dataUri =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFc'
          'SJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      final api = FakeApi();
      api.previews['https://example.com/article'] = const LinkPreview(
        url: 'https://example.com/article',
        title: 'Example article',
        image: dataUri,
      );
      await tester.pumpWidget(
        harness(api, const LinkPreviewCard(url: 'https://example.com/article')),
      );
      await tester.pumpAndSettle();

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((i) => i.image is MemoryImage), isTrue);
      expect(find.byIcon(Icons.public), findsNothing);
    });

    // Typing in a note rebuilds its previews on every keystroke. A fresh
    // MemoryImage per build is a new cache key, so the thumbnail reloaded and
    // faded in again each time: the flicker.
    testWidgets('a rebuild keeps the same data: image', (tester) async {
      const dataUri =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFc'
          'SJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      final api = FakeApi();
      api.previews['https://example.com/a'] = const LinkPreview(
        url: 'https://example.com/a',
        title: 'Article',
        image: dataUri,
      );
      final cache = LinkPreviewCache(api: api);
      Widget build(int keystrokes) => MaterialApp(
        home: Scaffold(
          body: Provider<LinkPreviewCache>.value(
            value: cache,
            child: Column(
              children: [
                Text('typed $keystrokes'),
                // Not const: the editor builds a new card on every keystroke.
                // ignore: prefer_const_constructors
                LinkPreviewCard(url: 'https://example.com/a'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(build(0));
      await tester.pumpAndSettle();
      final before = tester.widget<Image>(find.byType(Image).first).image;

      await tester.pumpWidget(build(1));
      final after = tester.widget<Image>(find.byType(Image).first).image;
      expect(after, before);
    });

    // A card built again for a link already fetched (a note's links shifting
    // while typing) must not flash the bare host for a frame first.
    testWidgets('a new card for a fetched link shows it at once', (
      tester,
    ) async {
      final api = FakeApi();
      api.previews['https://example.com/b'] = const LinkPreview(
        url: 'https://example.com/b',
        title: 'Fetched title',
        siteName: 'Example',
      );
      final cache = LinkPreviewCache(api: api);
      Widget build(Key key) => MaterialApp(
        home: Scaffold(
          body: Provider<LinkPreviewCache>.value(
            value: cache,
            child: LinkPreviewCard(key: key, url: 'https://example.com/b'),
          ),
        ),
      );
      await tester.pumpWidget(build(const ValueKey(1)));
      await tester.pumpAndSettle();

      await tester.pumpWidget(build(const ValueKey(2)));
      expect(find.text('Fetched title'), findsOneWidget);
    });

    // Typing a link one character at a time must not swap the preview, and
    // unfurl a partial address, on every keystroke.
    testWidgets('the list waits for typing to pause before changing', (
      tester,
    ) async {
      final api = FakeApi();
      final cache = LinkPreviewCache(api: api);
      Widget build(String text) => MaterialApp(
        home: Scaffold(
          body: Provider<LinkPreviewCache>.value(
            value: cache,
            child: LinkPreviewList(text: text),
          ),
        ),
      );
      await tester.pumpWidget(build('see https://example.com'));
      await tester.pumpAndSettle();
      expect(find.text('example.com'), findsOneWidget);

      await tester.pumpWidget(build('see https://example.co'));
      await tester.pump();
      await tester.pumpWidget(build('see https://example.c'));
      await tester.pump();
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('example.c'), findsNothing);

      await tester.pump(kLinkPreviewSettle);
      await tester.pumpAndSettle();
      expect(find.text('example.c'), findsOneWidget);
    });

    testWidgets('renders an absolute-URL favicon via NetworkImage', (
      tester,
    ) async {
      final api = FakeApi();
      api.previews['https://example.org'] = const LinkPreview(
        url: 'https://example.org',
        title: 'Example',
        siteName: 'example.org',
        favicon: 'https://example.org/favicon.png',
      );
      await tester.pumpWidget(
        harness(api, const LinkPreviewCard(url: 'https://example.org')),
      );
      await tester.pumpAndSettle();

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((i) => i.image is NetworkImage), isTrue);
    });
  });
}
