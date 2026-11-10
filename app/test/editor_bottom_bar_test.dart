import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/editor/editor_bottom_bar.dart';
import 'finders.dart';

void main() {
  Widget bar({
    double width = 390,
    VoidCallback? onImage,
    VoidCallback? onAttach,
    VoidCallback? onReminder,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: EditorBottomBar(
            trashed: false,
            editedStamp: 'Edited just now',
            onPalette: () {},
            onLabels: () {},
            onReminder: onReminder ?? () {},
            onImage: onImage ?? () {},
            onAttach: onAttach ?? () {},
            onUndo: () {},
            onRedo: () {},
          ),
        ),
      ),
    ),
  );

  testWidgets('an ordinary phone keeps every compose action in the row', (
    tester,
  ) async {
    await tester.pumpWidget(bar());

    // Seven 48px targets fit from 360 up, so nothing about composing a note is
    // behind a menu on a normal phone.
    for (final tooltip in [
      'Note color',
      'Labels',
      'Remind me',
      'Add image',
      'Attach file',
      'Undo',
      'Redo',
    ]) {
      expect(findAction(tooltip), findsOneWidget, reason: tooltip);
    }
    expect(findAction('Add to note'), findsNothing);
  });

  testWidgets('the smallest phones fold the two insert actions together', (
    tester,
  ) async {
    var addedImage = false;
    var attachedFile = false;
    await tester.pumpWidget(
      bar(
        width: 320,
        onImage: () => addedImage = true,
        onAttach: () => attachedFile = true,
      ),
    );

    // Reminder stays in the row: only inserting collapses, and it collapses
    // into one predictable category rather than a general overflow.
    expect(findAction('Remind me'), findsOneWidget);
    expect(findAction('Add image'), findsNothing);
    expect(findAction('Attach file'), findsNothing);

    await tester.tap(findAction('Add to note'));
    await tester.pumpAndSettle();
    expect(find.text('Add image'), findsOneWidget);
    expect(find.text('Attach file'), findsOneWidget);

    await tester.tap(find.text('Add image'));
    // The action only runs once the sheet has fully dismissed, avoiding two
    // surfaces overlapping while a platform picker or another route opens.
    await tester.pumpAndSettle();
    expect(addedImage, isTrue);

    await tester.tap(findAction('Add to note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach file'));
    await tester.pumpAndSettle();
    expect(attachedFile, isTrue);
  });

  testWidgets('the edited stamp only takes the middle band when wide', (
    tester,
  ) async {
    await tester.pumpWidget(bar(width: 700));
    expect(find.text('Edited just now'), findsOneWidget);

    await tester.pumpWidget(bar(width: 390));
    expect(find.text('Edited just now'), findsNothing);
  });
}
