import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/form_dialog.dart';

void main() {
  Widget launcher(Future<void> Function(BuildContext) onPressed) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => onPressed(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('selection surfaces use a bottom sheet on phones', (
    tester,
  ) async {
    useViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      launcher(
        (context) => showAdaptiveSelectionSurface<void>(
          context,
          builder: (context) => const ListTile(title: Text('Choice')),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Choice'), findsOneWidget);
  });

  testWidgets('selection surfaces stay compact and centered on web', (
    tester,
  ) async {
    useViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      launcher(
        (context) => showAdaptiveSelectionSurface<void>(
          context,
          builder: (context) => const ListTile(title: Text('Choice')),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester.getSize(find.widgetWithText(ListTile, 'Choice')).width,
      lessThanOrEqualTo(480),
    );
  });

  testWidgets('input forms become full-screen pages only on phones', (
    tester,
  ) async {
    Future<void> showEditor(BuildContext context) => showFormDialog<void>(
      context,
      builder: (context) => FormDialog(
        title: const Text('Edit details'),
        content: const TextField(),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );

    useViewport(tester, const Size(390, 844));
    await tester.pumpWidget(launcher(showEditor));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.widgetWithText(AppBar, 'Edit details'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpWidget(launcher(showEditor));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Edit details'), findsNothing);
  });

  testWidgets('phone form actions stay above the keyboard', (tester) async {
    Future<void> showEditor(BuildContext context) => showFormDialog<void>(
      context,
      builder: (context) => FormDialog(
        title: const Text('New workspace'),
        content: const TextField(autofocus: true),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    useViewport(tester, const Size(390, 844));
    await tester.pumpWidget(launcher(showEditor));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final createBottom = tester.getBottomRight(find.text('Create')).dy;
    expect(createBottom, lessThan(844 - 300));
    expect(tester.getRect(find.text('Create')).isEmpty, isFalse);
  });
}
