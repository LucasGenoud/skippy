import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/label_style.dart';
import 'package:skippy/widgets/labels_sheet.dart';

import 'fake_api.dart';

void main() {
  group('label_style', () {
    test('icon key resolves, unknown/empty falls back to default', () {
      expect(labelIconFor('work'), kLabelIcons['work']);
      expect(labelIconFor(null), kDefaultLabelIcon);
      expect(labelIconFor('does-not-exist'), kDefaultLabelIcon);
    });

    test('labelColor parses hex and falls back', () {
      const fallback = Color(0xFF123456);
      expect(
        labelColor(const Label(id: 'a', name: 'x', color: '#1A73E8'), fallback),
        const Color(0xFF1A73E8),
      );
      expect(labelColor(const Label(id: 'a', name: 'x'), fallback), fallback);
    });
  });

  group('LabelGlyph', () {
    testWidgets('renders the label icon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LabelGlyph(
              label: Label(
                id: 'l',
                name: 'work',
                color: '#1A73E8',
                icon: 'work',
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(kLabelIcons['work']!), findsOneWidget);
    });
  });

  group('LabelEditorDialog', () {
    testWidgets('creates a label with name, custom color, and icon', (
      tester,
    ) async {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u');
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NotesStore>.value(
            value: store,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => LabelEditorDialog.show(context, null),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Name (first field) + custom hex (second field).
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Work');
      await tester.enterText(fields.at(1), '#1A73E8');
      // Pick the 'work' icon from the grid.
      await tester.tap(find.byIcon(kLabelIcons['work']!));
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(store.labels, hasLength(1));
      final label = store.labels.single;
      expect(label.name, 'Work');
      expect(label.color, '#1A73E8');
      expect(label.icon, 'work');
    });

    testWidgets('an empty name shows an error and keeps the dialog open', (
      tester,
    ) async {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u');
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NotesStore>.value(
            value: store,
            child: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => LabelEditorDialog.show(context, null),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Save with a blank name → inline error, no label created, still open.
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      expect(store.labels, isEmpty);
      expect(find.text('New label'), findsOneWidget); // dialog still up

      // Typing clears the error; a valid save then works.
      await tester.enterText(find.byType(TextField).first, 'Work');
      await tester.pump();
      expect(find.text('Enter a name'), findsNothing);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(store.labels.single.name, 'Work');
    });

    testWidgets('a duplicate name is rejected with an error', (tester) async {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u');
      addTearDown(store.dispose);
      store.createLabel('Work'); // existing label

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NotesStore>.value(
            value: store,
            child: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => LabelEditorDialog.show(context, null),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Case-insensitive clash → error, no second label.
      await tester.enterText(find.byType(TextField).first, 'work');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('A label named "work" already exists'), findsOneWidget);
      expect(store.labels, hasLength(1));
    });
  });
}
