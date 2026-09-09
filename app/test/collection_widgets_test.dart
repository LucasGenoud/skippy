import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/board/board_view.dart';
import 'fake_api.dart';
import 'widget_test.dart' show homeApp;

void main() {
  for (final width in [390.0, 1200.0]) {
    testWidgets('create collection and switch layouts at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = NotesStore(api: FakeApi(), currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();
      if (width < 600) {
        await tester.tap(find.byIcon(Icons.menu));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('New collection'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Renovation');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(store.collections.last.name, 'Renovation');
      expect(store.composeCollectionId, store.collections.last.id);
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: 'Kitchen plan');
      await tester.pumpAndSettle();
      expect(find.text('Kitchen plan'), findsOneWidget);
      await tester.tap(find.byTooltip('Collection layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Board').last);
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsOneWidget);
      store.createStage('Planned');
      await tester.pumpAndSettle();
      expect(find.text('Kitchen plan'), findsOneWidget);
      await tester.tap(find.byTooltip('Collection layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Masonry').last);
      await tester.pumpAndSettle();
      expect(find.byType(BoardView), findsNothing);
      expect(find.text('Kitchen plan'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets(
    'a board collection keeps notes visible before its first column',
    (tester) async {
      final store = NotesStore(api: FakeApi(), currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      final collection = store.createCollection('Project', 'board');
      store.selectCollection(collection.id);
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: 'Unassigned project note');
      await tester.pumpWidget(homeApp(store));
      await tester.pumpAndSettle();
      expect(find.text('Unassigned project note'), findsOneWidget);
      expect(find.text('Add a column'), findsOneWidget);
    },
  );
}
