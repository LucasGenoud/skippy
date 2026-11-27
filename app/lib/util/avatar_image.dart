import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Side of the square a profile picture is stored at: sharp at the largest
/// size the app draws one (40 px) on a 4x screen, and small enough to keep
/// in the database.
const int kAvatarSide = 160;

/// [bytes] cropped to their centre square and scaled to [kAvatarSide], as
/// PNG. Null when the bytes are not a picture the engine can read.
Future<Uint8List?> squareAvatarPng(Uint8List bytes) async {
  try {
    // Decode at no more than twice the target, so a camera photo never sits
    // in memory at full resolution. Not through ImageDescriptor: its width
    // and height throw on web. The call disposes the buffer.
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: _decodeSize,
    );
    final source = (await codec.getNextFrame()).image;

    final side = math.min(source.width, source.height).toDouble();
    final crop = ui.Rect.fromLTWH(
      (source.width - side) / 2,
      (source.height - side) / 2,
      side,
      side,
    );
    final target = ui.Rect.fromLTWH(
      0,
      0,
      kAvatarSide.toDouble(),
      kAvatarSide.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      crop,
      target,
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final square = await recorder.endRecording().toImage(
      kAvatarSide,
      kAvatarSide,
    );
    final data = await square.toByteData(format: ui.ImageByteFormat.png);

    square.dispose();
    source.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// [width] x [height] shrunk so the short side is at most twice [kAvatarSide].
ui.TargetImageSize _decodeSize(int width, int height) {
  final scale = math.min(1.0, 2 * kAvatarSide / math.min(width, height));
  return ui.TargetImageSize(
    width: (width * scale).round(),
    height: (height * scale).round(),
  );
}
