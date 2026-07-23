import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/widgets/editor/editor_bottom_bar.dart';

void main() {
  testWidgets('small phones move secondary editor actions into More', (
    tester,
  ) async {
    var addedImage = false;
    var addedReminder = false;
    var attachedFile = false;
    var shared = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: EditorBottomBar(
                trashed: false,
                isOwner: true,
                archived: false,
                kind: NoteKind.text,
                editedStamp: 'Edited just now',
                onPalette: () {},
                onLabels: () {},
                onReminder: () => addedReminder = true,
                onImage: () => addedImage = true,
                onAttach: () => attachedFile = true,
                onShare: () => shared = true,
              ),
            ),
          ),
        ),
      ),
    );

    // At this width the two most frequent organisation controls, undo/redo,
    // and the overflow trigger stay in the row; none can be clipped at the
    // edge.
    expect(find.byTooltip('Note color'), findsOneWidget);
    expect(find.byTooltip('Labels'), findsOneWidget);
    expect(find.byTooltip('Undo'), findsOneWidget);
    expect(find.byTooltip('Redo'), findsOneWidget);
    expect(find.byTooltip('Remind me'), findsNothing);
    expect(find.byTooltip('Add image'), findsNothing);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Add image'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
    expect(find.text('Attach file'), findsOneWidget);
    expect(find.text('Collaborators'), findsOneWidget);

    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    expect(addedImage, isTrue);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remind me'));
    await tester.pumpAndSettle();
    expect(addedReminder, isTrue);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach file'));
    await tester.pumpAndSettle();
    expect(attachedFile, isTrue);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collaborators'));
    await tester.pumpAndSettle();
    expect(shared, isTrue);
  });

  testWidgets('AI note editing actions are available from More on phones', (
    tester,
  ) async {
    NoteRewriteMode? rewritten;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: EditorBottomBar(
              trashed: false,
              isOwner: true,
              archived: false,
              kind: NoteKind.text,
              editedStamp: 'Edited just now',
              onRewrite: (mode) => rewritten = mode,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Clean up and make concise'), findsOneWidget);
    expect(find.text('Fix grammar and syntax'), findsOneWidget);

    await tester.tap(find.text('Fix grammar and syntax'));
    await tester.pumpAndSettle();
    expect(rewritten, NoteRewriteMode.grammar);
  });
}
