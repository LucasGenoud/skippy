import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/image_png.dart';

void main() {
  test('a PNG passes through untouched', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    expect(await encodePng(png), same(png));
  });

  test('bytes that are not a picture give null', () async {
    expect(await encodePng(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
  });
}
