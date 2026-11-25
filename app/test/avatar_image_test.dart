import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/avatar_image.dart';

/// A [width] x [height] PNG.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<(int, int)> _size(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  return (image.width, image.height);
}

void main() {
  testWidgets('a wide picture becomes a small square', (tester) async {
    await tester.runAsync(() async {
      final square = await squareAvatarPng(await _png(900, 400));
      expect(square, isNotNull);
      expect(await _size(square!), (kAvatarSide, kAvatarSide));
    });
  });

  testWidgets('bytes that are not a picture give null', (tester) async {
    await tester.runAsync(() async {
      expect(await squareAvatarPng(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
