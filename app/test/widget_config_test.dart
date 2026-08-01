import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/screens/widget_config_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/home_widgets.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote, testStore;

/// Records what the configuration screen binds, standing in for the shared
/// store. Subclassed rather than method-channel-mocked, matching the fake in
/// home_widget_bridge_test.dart.
class RecordingHomeWidgets extends HomeWidgets {
  String? preselected;
  int? boundWidgetId;
  String? boundNoteId;

  @override
  Future<String?> takePreselectedNote() async => preselected;

  @override
  Future<void> bindWidgetToNote(int widgetId, String noteId) async {
    boundWidgetId = widgetId;
    boundNoteId = noteId;
  }
}

void main() {
  group('noteIdFromUri', () {
    test('reads the note id out of a widget tap', () {
      expect(
        HomeWidgets.noteIdFromUri(Uri.parse('skippy://note/abc-123?homeWidget=1')),
        'abc-123',
      );
    });

    test('ignores anything that is not one of our note links', () {
      for (final uri in [
        'https://example.com/note/abc',
        'skippy://settings/abc',
        'skippy://note/',
        'skippy://note',
      ]) {
        expect(
          HomeWidgets.noteIdFromUri(Uri.parse(uri)),
          isNull,
          reason: uri,
        );
      }
      expect(HomeWidgets.noteIdFromUri(null), isNull);
    });
  });

  group('WidgetConfigScreen', () {
    late FakeApi api;
    late NotesStore store;
    late RecordingHomeWidgets widgets;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: store,
          child: MaterialApp(
            home: WidgetConfigScreen(widgetId: 42, widgets: widgets),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      api = FakeApi();
      widgets = RecordingHomeWidgets();
      store = testStore(api);
    });

    tearDown(() => store.dispose());

    testWidgets('lists notes and binds the one that is picked', (tester) async {
      api.notes['n1'] = serverNote('n1', title: 'Groceries');
      api.notes['n2'] = serverNote('n2', title: 'Wifi password');
      await store.load();
      await pump(tester);

      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Wifi password'), findsOneWidget);

      await tester.tap(find.text('Groceries'));
      await tester.pumpAndSettle();

      expect(widgets.boundWidgetId, 42);
      expect(widgets.boundNoteId, 'n1');
    });

    testWidgets('puts the note the user pinned from first', (tester) async {
      api.notes['old'] = serverNote(
        'old',
        title: 'Pinned from here',
        updatedAt: DateTime.utc(2020),
      );
      api.notes['new'] = serverNote(
        'new',
        title: 'Edited recently',
        updatedAt: DateTime.utc(2026),
      );
      await store.load();
      widgets.preselected = 'old';
      await pump(tester);

      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(titles.first, 'Pinned from here');
    });

    testWidgets('search narrows the list', (tester) async {
      api.notes['n1'] = serverNote('n1', title: 'Groceries');
      api.notes['n2'] = serverNote('n2', title: 'Wifi password');
      await store.load();
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'wifi');
      await tester.pumpAndSettle();

      expect(find.text('Groceries'), findsNothing);
      expect(find.text('Wifi password'), findsOneWidget);
    });

    testWidgets('a trashed note can never be put on the home screen', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', title: 'Groceries');
      api.notes['n2'] = serverNote('n2', title: 'Binned', trashed: true);
      await store.load();
      await pump(tester);

      expect(find.text('Binned'), findsNothing);
      expect(find.text('Groceries'), findsOneWidget);
    });

    testWidgets('an untitled note still shows something pickable', (
      tester,
    ) async {
      api.notes['n1'] = serverNote('n1', content: 'buy milk and eggs');
      await store.load();
      await pump(tester);

      expect(find.text('buy milk and eggs'), findsOneWidget);
    });
  });
}
