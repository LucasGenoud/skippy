import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sticky_notes/models/link_preview.dart';
import 'package:sticky_notes/state/link_preview_cache.dart';
import 'package:sticky_notes/widgets/link_preview.dart';
import 'package:sticky_notes/widgets/linked_text.dart';

import 'fake_api.dart';

void main() {
  group('LinkedText', () {
    testWidgets('long-pressing a URL opens it', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkedText(
              text: 'https://example.com',
              onOpen: opened.add,
            ),
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
          LinkPreviewCard(
            url: 'https://youtube.com',
            onOpen: opened.add,
          ),
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
  });
}
