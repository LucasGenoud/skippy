import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:skippy/widgets/pick_image.dart';

void main() {
  ImageSource? chosen;

  Widget launcher() => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () async => chosen = await chooseImageSource(context),
            child: const Text('Add image'),
          ),
        ),
      ),
    ),
  );

  setUp(() => chosen = null);

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  test('only the platforms with a camera intent offer one', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        canTakePhoto,
        platform == TargetPlatform.android || platform == TargetPlatform.iOS,
        reason: '$platform',
      );
    }
  });

  testWidgets(
    'the camera is a choice next to the gallery',
    (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(launcher());
      await tester.tap(find.text('Add image'));
      await tester.pumpAndSettle();

      expect(find.text('Take photo'), findsOneWidget);
      await tester.tap(find.text('Take photo'));
      await tester.pumpAndSettle();

      expect(chosen, ImageSource.camera);
    },
    variant: TargetPlatformVariant.mobile(),
  );

  testWidgets(
    'the gallery stays one tap away in the same sheet',
    (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(launcher());
      await tester.tap(find.text('Add image'));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Choose from'));
      await tester.pumpAndSettle();

      expect(chosen, ImageSource.gallery);
    },
    variant: TargetPlatformVariant.mobile(),
  );

  testWidgets(
    'backing out of the sheet picks nothing',
    (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(launcher());
      await tester.tap(find.text('Add image'));
      await tester.pumpAndSettle();

      // The barrier above the sheet.
      await tester.tapAt(const Offset(195, 40));
      await tester.pumpAndSettle();

      expect(chosen, isNull);
    },
    variant: TargetPlatformVariant.mobile(),
  );
}
