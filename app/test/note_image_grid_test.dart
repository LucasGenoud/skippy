import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/dropped_file.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/editor/attachment_tiles.dart';
import 'package:skippy/widgets/image_mosaic.dart';
import 'package:skippy/widgets/note_card.dart';

import 'fake_api.dart';
import 'finders.dart';
import 'notes_store_test.dart' show serverNote;
import 'swipe_to_archive_test.dart' show phoneApp;

List<Attachment> photos(int count) => [
  for (var i = 0; i < count; i++)
    Attachment(id: 'p$i', mime: 'image/jpeg', filename: 'photo-$i.jpg'),
];

Finder cardTile(int i) => find.byKey(ValueKey('card-image-p$i'));

void main() {
  group('mosaicLayout', () {
    const width = 240.0;

    MosaicFrame card(int count, {double? aspect}) => mosaicLayout(
      MosaicStyle.card,
      count: count,
      width: width,
      leadAspect: aspect,
    );

    test('one picture spans the card at its own shape, capped', () {
      expect(
        card(1, aspect: 2).tiles.single,
        const Rect.fromLTWH(0, 0, 240, 120),
      );
      expect(card(1, aspect: 0.25).height, 280);
    });

    test('two sit side by side', () {
      final tiles = card(2).tiles;
      expect(tiles[0].top, tiles[1].top);
      expect(tiles[0].width, tiles[1].width);
      expect(tiles[1].left, greaterThan(tiles[0].right));
      expect(tiles[1].right, width);
    });

    test('three are one wide picture over two small ones', () {
      final tiles = card(3).tiles;
      expect(tiles[0].width, width);
      expect(tiles[1].top, tiles[2].top);
      expect(tiles[1].top, greaterThan(tiles[0].bottom));
      expect(tiles[1].width, lessThan(tiles[0].width / 2 + 1));
    });

    test('four and more are a two by two grid', () {
      for (final count in [4, 7]) {
        final tiles = card(count).tiles;
        expect(tiles, hasLength(4));
        expect(tiles[0].top, tiles[1].top);
        expect(tiles[2].top, tiles[3].top);
        expect(tiles[0].left, tiles[2].left);
        expect(tiles[3].right, width);
      }
    });

    test('nothing on a card grows past its height cap', () {
      for (var count = 1; count <= 6; count++) {
        final frame = mosaicLayout(
          MosaicStyle.card,
          count: count,
          width: 400,
          leadAspect: 0.5,
        );
        expect(frame.height, lessThanOrEqualTo(280));
        expect(frame.tiles.last.bottom, frame.height);
      }
    });

    test('the editor lays every picture out, three across when wide', () {
      final narrow = mosaicLayout(MosaicStyle.editor, count: 5, width: 360);
      expect(narrow.tiles, hasLength(5));
      expect(narrow.tiles[2].left, 0);

      final wide = mosaicLayout(MosaicStyle.editor, count: 5, width: 640);
      expect(wide.tiles[2].top, wide.tiles[0].top);
      expect(wide.tiles[3].left, 0);
      expect(wide.height, wide.tiles.last.bottom);
    });
  });

  group('card image grid', () {
    late FakeApi api;
    late NotesStore store;

    setUp(() {
      api = FakeApi();
      store = NotesStore(api: api, currentUserId: 'u-me');
    });
    tearDown(() => store.dispose());

    Future<void> pumpCard(WidgetTester tester, int count) async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Trip',
      ).copyWith(attachments: photos(count));
      await store.refresh();
      await tester.pumpWidget(
        phoneApp(
          store,
          Center(
            child: SizedBox(
              width: 240,
              child: NoteTile(note: store.noteById('n1')!),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> setImages(WidgetTester tester, int count) async {
      await tester.pumpWidget(
        phoneApp(
          store,
          Center(
            child: SizedBox(
              width: 240,
              child: NoteTile(
                note: store
                    .noteById('n1')!
                    .copyWith(attachments: photos(count)),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('one picture fills the card width', (tester) async {
      await pumpCard(tester, 1);
      final tile = tester.getRect(cardTile(0));
      expect(tile.width, 240);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('two pictures sit side by side', (tester) async {
      await pumpCard(tester, 2);
      final a = tester.getRect(cardTile(0));
      final b = tester.getRect(cardTile(1));
      expect(a.top, b.top);
      expect(a.width, b.width);
      expect(b.left - a.right, 2);
    });

    testWidgets('three pictures are one large over two small', (tester) async {
      await pumpCard(tester, 3);
      final large = tester.getRect(cardTile(0));
      final left = tester.getRect(cardTile(1));
      final right = tester.getRect(cardTile(2));
      expect(large.width, 240);
      expect(left.top, right.top);
      expect(left.top - large.bottom, 2);
    });

    testWidgets('four pictures are a two by two grid with no count', (
      tester,
    ) async {
      await pumpCard(tester, 4);
      final rects = [for (var i = 0; i < 4; i++) tester.getRect(cardTile(i))];
      expect(rects[0].top, rects[1].top);
      expect(rects[2].top, rects[3].top);
      expect(rects[0].left, rects[2].left);
      expect(rects[0].size, rects[3].size);
      expect(find.text('+0'), findsNothing);
      final scrim = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: cardTile(3),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(scrim.opacity, 0);
    });

    testWidgets('more than four counts the rest on the last tile', (
      tester,
    ) async {
      await pumpCard(tester, 7);
      expect(cardTile(4), findsNothing);
      expect(
        find.descendant(of: cardTile(3), matching: find.text('+3')),
        findsOneWidget,
      );
      final scrim = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: cardTile(3),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(scrim.opacity, 1);
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == '7 images',
        ),
        findsOneWidget,
      );
    });

    testWidgets('adding a picture moves the grid instead of snapping', (
      tester,
    ) async {
      await pumpCard(tester, 1);
      final before = tester.getRect(cardTile(0));

      await setImages(tester, 2);
      await tester.pump(const Duration(milliseconds: 60));
      final during = tester.getRect(cardTile(0));
      // On its way from the full width to half of it, not at either end.
      expect(during.width, lessThan(before.width));
      expect(during.width, greaterThan(119));
      final arriving = tester.widget<FadeTransition>(
        find
            .ancestor(of: cardTile(1), matching: find.byType(FadeTransition))
            .first,
      );
      expect(arriving.opacity.value, inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(tester.getRect(cardTile(0)).width, 119);
    });

    testWidgets('removing a picture fades it out where it was', (tester) async {
      await pumpCard(tester, 3);
      final leavingRect = tester.getRect(cardTile(2));

      await setImages(tester, 2);
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getRect(cardTile(2)), leavingRect);
      final leaving = tester.widget<FadeTransition>(
        find
            .ancestor(of: cardTile(2), matching: find.byType(FadeTransition))
            .first,
      );
      expect(leaving.opacity.value, inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(cardTile(2), findsNothing);
    });
  });

  group('editor images', () {
    Widget editor(
      List<Attachment> attachments, {
      List<DroppedFile> uploading = const [],
      void Function(Attachment)? onRemove,
    }) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: attachmentTiles(
              attachments: attachments,
              uploading: uploading,
              urlOf: (a) => 'http://fake.test/files/${a.id}',
              onRemove: onRemove,
            ),
          ),
        ),
      ),
    );

    testWidgets('every picture shows and any one can be removed', (
      tester,
    ) async {
      final removed = <String>[];
      await tester.pumpWidget(
        editor(photos(6), onRemove: (a) => removed.add(a.id)),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        expect(find.byKey(Key('open-image-p$i')), findsOneWidget);
      }

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('p4')),
          matching: findAction('Remove image'),
        ),
      );
      expect(removed, ['p4']);
    });

    testWidgets('an upload holds its slot in the grid', (tester) async {
      await tester.pumpWidget(
        editor(
          photos(2),
          uploading: [
            DroppedFile(
              name: 'new.png',
              mime: 'image/png',
              bytes: Uint8List(4),
            ),
          ],
        ),
      );
      await tester.pump();
      final first = tester.getRect(find.byKey(const ValueKey('p0')));
      final pending = tester.getRect(find.byType(UploadingAttachmentTile));
      expect(pending.width, closeTo(first.width, 0.01));
      expect(pending.height, closeTo(first.height, 0.01));
      expect(pending.top, closeTo(first.top, 0.01));
    });

    testWidgets('the viewer steps through every picture', (tester) async {
      await tester.pumpWidget(editor(photos(3)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-image-p1')));
      await tester.pumpAndSettle();

      final position = find.byKey(const Key('image-viewer-position'));
      expect(tester.widget<Text>(position).data, '2 / 3');
      expect(find.byKey(const Key('full-image-p1')), findsOneWidget);

      await tester.tap(findAction('Next image'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(position).data, '3 / 3');
      expect(find.byKey(const Key('full-image-p2')), findsOneWidget);
      // The last picture has nowhere further to go.
      final next = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: findAction('Next image'),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(next.opacity, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(position).data, '1 / 3');

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(position).data, '2 / 3');
    });
  });
}
