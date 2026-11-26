import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/drawing.dart';

void main() {
  const line = Stroke(
    color: 0xE5484D,
    width: 8,
    points: [Offset(10, 20), Offset(110, 20), Offset(110, 220)],
  );
  const dot = Stroke(width: 4, points: [Offset(500, 500)]);

  test('strokes survive encoding, as whole units with deltas', () {
    final encoded = const Drawing([line, dot]).encode();
    expect(encoded, contains('"p":[10,20,100,0,0,200]'));

    final back = Drawing.parse(encoded);
    expect(back.strokes, hasLength(2));
    expect(back.strokes.first.color, 0xE5484D);
    expect(back.strokes.first.width, 8);
    expect(back.strokes.first.points, line.points);
    expect(back.strokes.last.color, isNull);
    expect(back.strokes.last.points, dot.points);
  });

  test('a blank sheet encodes as no content at all', () {
    expect(Drawing.empty.encode(), '');
    expect(Drawing.parse('').isEmpty, isTrue);
  });

  test('unreadable content reads as an empty drawing', () {
    expect(Drawing.parse('not json').isEmpty, isTrue);
    expect(Drawing.parse('{"s":[{"p":"x"}]}').isEmpty, isTrue);
    expect(Drawing.parse('[1,2]').isEmpty, isTrue);
  });

  test('the eraser removes only strokes it touches', () {
    const drawing = Drawing([line, dot]);
    expect(drawing.eraseAt(const Offset(60, 24), 2).strokes, [dot]);
    expect(
      identical(drawing.eraseAt(const Offset(800, 50), 2), drawing),
      isTrue,
    );
  });

  test('content height reaches the lowest stroke edge', () {
    expect(const Drawing([line]).contentHeight, 224);
  });

  test('bounds hold every stroke, edges included', () {
    expect(
      const Drawing([line, dot]).bounds,
      const Rect.fromLTRB(6, 16, 502, 502),
    );
    expect(Drawing.empty.bounds, Rect.zero);
  });

  test('simplifying keeps the corners and drops the samples between', () {
    final samples = [
      for (var x = 0; x <= 100; x++) Offset(x.toDouble(), 0),
      for (var y = 1; y <= 100; y++) Offset(100, y.toDouble()),
    ];
    expect(simplifyStroke(samples), const [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
    ]);
  });

  test('a drawing has no prose for search, exports or previews', () {
    final note = Note(
      id: 'n',
      kind: NoteKind.fromWire('drawing'),
      content: const Drawing([line]).encode(),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    expect(note.kind, NoteKind.drawing);
    expect(note.isDrawing, isTrue);
    expect(note.prose, '');
    expect(note.isEmpty, isFalse);
  });
}
