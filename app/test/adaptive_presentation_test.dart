import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/theme.dart';
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

  group('modal chrome', () {
    /// Header, body and footer must start on the same vertical line: a footer
    /// that sat 8px inside the body above it is exactly what made the app's
    /// modals look hand-assembled.
    Future<void> pumpChrome(WidgetTester tester) => tester.pumpWidget(
      launcher(
        (context) => showAdaptiveSelectionSurface<void>(
          context,
          builder: (context) => const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ModalHeader(title: 'Pick one', subtitle: 'Any one will do'),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: kModalInset),
                child: Text('Body'),
              ),
              ModalFooter(
                children: [
                  Expanded(child: Text('Footer')),
                  Text('Save'),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    testWidgets('one left edge in a dialog', (tester) async {
      useViewport(tester, const Size(1200, 800));
      await pumpChrome(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final title = tester.getTopLeft(find.text('Pick one')).dx;
      expect(tester.getTopLeft(find.text('Any one will do')).dx, title);
      expect(tester.getTopLeft(find.text('Body')).dx, title);
      expect(tester.getTopLeft(find.text('Footer')).dx, title);
      // And that edge is the shared one, measured from the surface itself.
      expect(
        title - tester.getTopLeft(find.byType(ModalHeader)).dx,
        kModalInset,
      );
    });

    testWidgets('one left edge in a sheet', (tester) async {
      useViewport(tester, const Size(390, 844));
      await pumpChrome(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final title = tester.getTopLeft(find.text('Pick one')).dx;
      expect(tester.getTopLeft(find.text('Body')).dx, title);
      expect(tester.getTopLeft(find.text('Footer')).dx, title);
      expect(
        title - tester.getTopLeft(find.byType(ModalHeader)).dx,
        kModalInset,
      );
    });

    testWidgets('a dialog title lines up with its content', (tester) async {
      useViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(
        launcher(
          (context) => showDialog<void>(
            context: context,
            builder: (context) => const AppDialog(
              title: Text('Delete this?'),
              content: Text('It does not come back.'),
              actions: [Text('Cancel')],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // The painted surface, not the AlertDialog element, which lays itself
      // out across the whole screen and centres its box inside.
      final dialogLeft = tester
          .getTopLeft(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(Material),
                )
                .first,
          )
          .dx;
      expect(
        tester.getTopLeft(find.text('Delete this?')).dx - dialogLeft,
        kModalInset,
      );
      expect(
        tester.getTopLeft(find.text('It does not come back.')).dx - dialogLeft,
        kModalInset,
      );
    });

    testWidgets('a dialog title is the shared title style', (tester) async {
      useViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(
        launcher(
          (context) => showDialog<void>(
            context: context,
            builder: (context) => const AppDialog(
              title: Text('Delete this?'),
              content: Text('It does not come back.'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('Delete this?'));
      final expected = Theme.of(context).textTheme.titleLarge;
      // The size is what a style frozen at theme-construction time loses, so
      // it is the half worth asserting.
      expect(expected?.fontSize, isNotNull);
      expect(DefaultTextStyle.of(context).style.fontSize, expected!.fontSize);
    });
  });
}
