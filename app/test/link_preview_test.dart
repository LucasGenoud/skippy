import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/link_preview.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/widgets/link_preview.dart';
import 'package:skippy/widgets/linked_text.dart';

import 'fake_api.dart';

void main() {
  group('LinkedText', () {
    testWidgets('long-pressing a URL opens it', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkedText(text: 'https://example.com', onOpen: opened.add),
          ),
        ),
      );

      await tester.longPress(find.byType(LinkedText));
      await tester.pump();
      expect(opened, ['https://example.com']);
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

    // The server inlines small favicons as `data:` URIs so Flutter web can
    // render them (a cross-origin favicon is CORS-tainted on CanvasKit). Those
    // must decode to bytes — mobile's NetworkImage can't fetch the data: scheme.
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
