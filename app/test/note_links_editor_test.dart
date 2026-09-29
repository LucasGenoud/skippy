import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/editor/highlighted_text_field.dart';

import 'checklist_test.dart' show harness, settleQueue;
import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

const _source = '11111111-1111-4111-8111-111111111111';
const _target = '22222222-2222-4222-8222-222222222222';

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  Finder body() => find.descendant(
    of: find.byType(HighlightedTextField),
    matching: find.byType(EditableText),
  );

  Future<void> type(WidgetTester tester, String text) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await tester.pump();
  }

  testWidgets('typing [[ offers notes and picking one links it', (
    tester,
  ) async {
    api.notes[_source] = serverNote(_source, title: 'Plan');
    api.notes[_target] = serverNote(_target, title: 'Groceries');
    await store.load();
    await tester.pumpWidget(
      harness(store, const EditorScreen(noteId: _source)),
    );
    await tester.pumpAndSettle();

    await tester.tap(body());
    await tester.pump();
    await type(tester, 'buy [[gro');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-link-picker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-link-option-$_target')));
    await settleQueue(tester);

    expect(store.noteById(_source)!.content, 'buy [[$_target|Groceries]] ');
    expect(find.byKey(const Key('note-link-picker')), findsNothing);
    expect(find.byKey(const ValueKey('LINKS-$_target')), findsOneWidget);
  });

  testWidgets('one backspace after a link removes all of it', (tester) async {
    const linked = 'buy [[$_target|Groceries]]';
    api.notes[_source] = serverNote(_source, content: linked);
    api.notes[_target] = serverNote(_target, title: 'Groceries');
    await store.load();
    await tester.pumpWidget(
      harness(store, const EditorScreen(noteId: _source)),
    );
    await tester.pumpAndSettle();

    await tester.tap(body());
    await tester.pump();
    await type(tester, linked.substring(0, linked.length - 1));
    await settleQueue(tester);

    expect(store.noteById(_source)!.content, 'buy ');
  });

  testWidgets('a linked note lists the notes linking to it', (tester) async {
    api.notes[_source] = serverNote(
      _source,
      title: 'Plan',
      content: 'see [[$_target|Groceries]]',
    );
    api.notes[_target] = serverNote(_target, title: 'Groceries');
    await store.load();
    await tester.pumpWidget(
      harness(store, const EditorScreen(noteId: _target)),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('LINKED FROM-$_source'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.text('Plan')),
      findsOneWidget,
    );
  });
}
