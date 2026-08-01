import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/note_routes.dart';

/// Stands in for the editor: what matters here is which routes the navigator
/// ends up holding, not what they draw.
Widget _note(String id) => Scaffold(body: Text('editor $id'));

void main() {
  late OpenNoteRoutes open;
  late GlobalKey<NavigatorState> key;

  Future<void> pump(WidgetTester tester) async {
    open = OpenNoteRoutes();
    key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: [open],
        home: const Scaffold(body: Text('the list')),
      ),
    );
  }

  /// What a home-screen widget tap does.
  Future<void> tapWidgetFor(WidgetTester tester, String id) async {
    open.showNote(key.currentState!, id, (_) => _note(id));
    await tester.pumpAndSettle();
  }

  testWidgets('a widget tap opens the note', (tester) async {
    await pump(tester);
    await tapWidgetFor(tester, 'n1');

    expect(find.text('editor n1'), findsOneWidget);
    expect(open.isOpen(noteRouteName('n1')), isTrue);
  });

  testWidgets('tapping the same widget again does not stack a second copy', (
    tester,
  ) async {
    await pump(tester);
    await tapWidgetFor(tester, 'n1');
    await tapWidgetFor(tester, 'n1');
    await tapWidgetFor(tester, 'n1');

    expect(find.text('editor n1'), findsOneWidget);
    // One back press is enough to reach the list again.
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('the list'), findsOneWidget);
    expect(open.isOpen(noteRouteName('n1')), isFalse);
  });

  testWidgets('tapping a widget for a note already open behind another one '
      'comes back to it', (tester) async {
    await pump(tester);
    await tapWidgetFor(tester, 'n1');
    await tapWidgetFor(tester, 'n2');
    await tapWidgetFor(tester, 'n1');

    expect(find.text('editor n1'), findsOneWidget);
    expect(find.text('editor n2'), findsNothing);
    expect(open.isOpen(noteRouteName('n2')), isFalse);
  });

  testWidgets('a different note still opens', (tester) async {
    await pump(tester);
    await tapWidgetFor(tester, 'n1');
    await tapWidgetFor(tester, 'n2');

    expect(find.text('editor n2'), findsOneWidget);
    expect(open.isOpen(noteRouteName('n1')), isTrue);
  });

  testWidgets('a note opened inside the app is raised, not opened twice', (
    tester,
  ) async {
    await pump(tester);
    // What a note card's OpenContainer does: a named route of its own.
    key.currentState!.push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: noteRouteName('n1')),
        builder: (_) => _note('n1'),
      ),
    );
    await tester.pumpAndSettle();

    await tapWidgetFor(tester, 'n1');

    // A stacked duplicate would render identically (the copy underneath is
    // offstage), so the check is that one back press still reaches the list.
    expect(find.text('editor n1'), findsOneWidget);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('the list'), findsOneWidget);
  });

  testWidgets('anything covering the note is dismissed', (tester) async {
    await pump(tester);
    await tapWidgetFor(tester, 'n1');
    showDialog<void>(
      context: key.currentContext!,
      builder: (_) => const AlertDialog(content: Text('a dialog')),
    );
    await tester.pumpAndSettle();
    expect(find.text('a dialog'), findsOneWidget);

    await tapWidgetFor(tester, 'n1');

    expect(find.text('a dialog'), findsNothing);
    expect(find.text('editor n1'), findsOneWidget);
  });

  testWidgets('the note is forgotten once it is closed', (tester) async {
    await pump(tester);
    await tapWidgetFor(tester, 'n1');
    key.currentState!.pop();
    await tester.pumpAndSettle();

    expect(open.isOpen(noteRouteName('n1')), isFalse);

    // ...and a later tap opens it again rather than popping to nothing.
    await tapWidgetFor(tester, 'n1');
    expect(find.text('editor n1'), findsOneWidget);
    expect(find.text('the list'), findsNothing);
  });
}
