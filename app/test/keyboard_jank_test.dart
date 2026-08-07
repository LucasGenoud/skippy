import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show harness, homeApp, flushTimers;

/// What the soft keyboard costs while it slides.
///
/// The keyboard animates its inset over ~15 frames, and every widget rebuilt
/// during those frames competes with the animation for the frame budget. The
/// grid used to rebuild wholesale on each one: the notes list is built inside a
/// `LayoutBuilder`, which re-runs on any constraint change, and the keyboard
/// changes the available *height* on every frame even though the builder only
/// reads the width. That dropped every card's cached widget and rebuilt ~2,000
/// widgets per frame, on the two screens where a keyboard is most likely to be
/// open.
///
/// These bounds are generous (measured at roughly 150 and 30 per frame); they
/// are here to fail loudly if the caching that keeps them low is removed, not
/// to pin an exact number.
void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  Future<int> rebuildsDuring(Future<void> Function() action) async {
    var count = 0;
    final printer = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => count++;
    debugPrintRebuildDirtyWidgets = true;
    await action();
    debugPrintRebuildDirtyWidgets = false;
    debugPrint = printer;
    return count;
  }

  /// Ten frames of a keyboard coming up. iOS keeps the view its full size and
  /// grows `viewInsets`; Android's activity is `adjustResize`, so the view
  /// itself shrinks. Both have to stay cheap, and they are separate paths
  /// through MediaQuery, so both are measured.
  Future<int> keyboardOpens(WidgetTester tester, {required bool resize}) {
    final full = tester.view.physicalSize;
    return rebuildsDuring(() async {
      for (var i = 1; i <= 10; i++) {
        final keyboard = 90.0 * i;
        if (resize) {
          tester.view.physicalSize = Size(full.width, full.height - keyboard);
        } else {
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> openHome(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      api.notes['n$i'] = serverNote('n$i', title: 'T$i', content: 'body $i');
    }
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
  }

  Future<void> openChecklist(WidgetTester tester) async {
    api.notes['n1'] = serverNote(
      'n1',
      kind: NoteKind.checklist,
      items: [
        for (var i = 0; i < 30; i++) ChecklistItem(id: 'i$i', text: 'item $i'),
      ],
    );
    await store.load();
    await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'n1')));
    await tester.pumpAndSettle();
  }

  group('the keyboard opening over the note grid', () {
    testWidgets('costs little while the inset grows (iOS)', (tester) async {
      phone(tester);
      await openHome(tester);
      expect(await keyboardOpens(tester, resize: false), lessThan(4000));
      await flushTimers(tester);
    });

    testWidgets('costs little while the view shrinks (Android)', (
      tester,
    ) async {
      phone(tester);
      await openHome(tester);
      expect(await keyboardOpens(tester, resize: true), lessThan(4000));
      await flushTimers(tester);
    });
  });

  group('the keyboard opening over a checklist', () {
    testWidgets('costs little while the inset grows (iOS)', (tester) async {
      phone(tester);
      await openChecklist(tester);
      expect(await keyboardOpens(tester, resize: false), lessThan(1500));
      await flushTimers(tester);
    });

    testWidgets('costs little while the view shrinks (Android)', (
      tester,
    ) async {
      phone(tester);
      await openChecklist(tester);
      expect(await keyboardOpens(tester, resize: true), lessThan(1500));
      await flushTimers(tester);
    });
  });
}
