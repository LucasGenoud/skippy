import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/home_fabs.dart';
import 'package:skippy/widgets/screen_width.dart';

import 'fake_api.dart';

const _kinds = ['Note', 'Checklist', 'Markdown', 'Audio'];

void main() {
  late NotesStore store;

  setUp(() => store = NotesStore(api: FakeApi(), currentUserId: 'u-me'));
  tearDown(() => store.dispose());

  Future<void> pumpFabs(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await store.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider(create: (_) => SettingsStore(api: store.api)),
          Provider(create: (_) => LinkPreviewCache(api: store.api)),
        ],
        child: MaterialApp(
          builder: (context, child) =>
              ScreenWidth(child: child ?? const SizedBox()),
          home: const Scaffold(
            body: Stack(
              children: [
                Positioned.fill(child: Center(child: Text('grid'))),
                Positioned(right: 16, bottom: 16, child: NewNoteFabs()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder shown(String kind) => find.text(kind).hitTestable();

  void expectMenu(bool open) {
    for (final kind in _kinds) {
      expect(shown(kind), open ? findsOneWidget : findsNothing, reason: kind);
    }
  }

  testWidgets('one button holds every kind of note until asked', (
    tester,
  ) async {
    await pumpFabs(tester);
    expectMenu(false);

    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();
    expectMenu(true);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expectMenu(false);
  });

  testWidgets('tapping anywhere else folds the menu', (tester) async {
    await pumpFabs(tester);
    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('grid'));
    await tester.pumpAndSettle();
    expectMenu(false);
  });

  testWidgets('a kind opens its editor, and the menu is folded after', (
    tester,
  ) async {
    await pumpFabs(tester);
    await tester.tap(find.byTooltip('New note'));
    await tester.pumpAndSettle();

    await tester.tap(shown('Checklist'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditorScreen>(find.byType(EditorScreen)).kind,
      NoteKind.checklist,
    );

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expectMenu(false);
  });
}
