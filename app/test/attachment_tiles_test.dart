import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/widgets/editor/attachment_tiles.dart';

void main() {
  testWidgets(
    'tapping an open-note image shows the entire image in a mobile viewer',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ImageAttachmentTile(
                attachment: Attachment(
                  id: 'photo-1',
                  mime: 'image/jpeg',
                  filename: 'receipt.jpg',
                ),
                url: 'http://fake.test/api/files/photo-1',
              ),
            ),
          ),
        ),
      );

      tester
          .widget<GestureDetector>(find.byKey(const Key('open-image-photo-1')))
          .onTap!();
      await tester.pump();

      expect(find.byKey(const Key('image-viewer')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final fullImage = tester.widget<Image>(
        find.byKey(const Key('full-image-photo-1')),
      );
      expect(fullImage.fit, BoxFit.contain);

      await tester.tap(find.byTooltip('Close image'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image-viewer')), findsNothing);
    },
    variant: TargetPlatformVariant.mobile(),
  );
}
