import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/editor_screen.dart';
import 'package:skippy/state/drawing.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/note_export.dart';
import 'package:skippy/widgets/drawing/drawing_canvas.dart';
import 'package:skippy/widgets/drawing/drawing_painter.dart';

import 'fake_api.dart';
import 'finders.dart';
import 'notes_store_test.dart' show serverNote;
import 'widget_test.dart' show harness;

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() async {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
    await store.load();
  });

  tearDown(() => store.dispose());

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The sheet strokes are drawn on.
  Finder sheet() => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is DrawingPainter,
    description: 'drawing sheet',
  );

  Note? drawingNote() {
    for (final note in store.notesForWidgets) {
      if (note.isDrawing) {
        return note;
      }
    }
    return null;
  }

  testWidgets('a stroke drawn on a new sheet saves a drawing note', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(
      harness(store, const EditorScreen(kind: NoteKind.drawing)),
    );
    await tester.pumpAndSettle();

    final start = tester.getTopLeft(sheet()) + const Offset(40, 40);
    await tester.dragFrom(start, const Offset(120, 60));
    await tester.pumpAndSettle();

    final note = drawingNote();
    expect(note, isNotNull);
    expect(note!.prose, isEmpty);
    final strokes = Drawing.parse(note.content).strokes;
    expect(strokes, hasLength(1));
    expect(strokes.single.points.length, greaterThanOrEqualTo(2));
  });

  testWidgets('each stroke is its own undo step', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      harness(store, const EditorScreen(kind: NoteKind.drawing)),
    );
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(sheet());
    await tester.dragFrom(origin + const Offset(40, 40), const Offset(100, 0));
    await tester.pumpAndSettle();
    await tester.dragFrom(origin + const Offset(40, 120), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(Drawing.parse(drawingNote()!.content).strokes, hasLength(2));

    await tester.tap(findAction('Undo').last);
    await tester.pumpAndSettle();
    expect(Drawing.parse(drawingNote()!.content).strokes, hasLength(1));
  });

  testWidgets('the eraser removes the stroke it crosses', (tester) async {
    await phone(tester);
    const stroke = Stroke(
      width: 8,
      points: [Offset(100, 100), Offset(600, 100)],
    );
    api.notes['d1'] = serverNote(
      'd1',
      kind: NoteKind.drawing,
      content: const Drawing([stroke]).encode(),
    );
    await store.load();
    await tester.pumpWidget(harness(store, const EditorScreen(noteId: 'd1')));
    await tester.pumpAndSettle();

    await tester.tap(findAction('Eraser').last);
    await tester.pump();
    // The stroke runs across the sheet at a tenth of its width down; drag
    // through it from above.
    final box = tester.getRect(sheet());
    final scale = box.width / kDrawingWidth;
    final across = box.topLeft + Offset(300 * scale, 60 * scale);
    await tester.dragFrom(across, Offset(0, 80 * scale));
    await tester.pumpAndSettle();

    expect(store.noteById('d1')!.content, isEmpty);
  });

  test('a drawing exports as a placeholder, never as its strokes', () {
    final note = serverNote(
      'd',
      title: 'Cat',
      kind: NoteKind.drawing,
      content: const Drawing([
        Stroke(width: 4, points: [Offset(1, 1)]),
      ]).encode(),
    );
    final text = noteToPlainText(note);
    expect(text, contains('Cat'));
    expect(text, contains('(drawing)'));
    expect(text, isNot(contains('"s"')));
  });

  Drawing dot(double x, double y) => Drawing([
    Stroke(width: 8, points: [Offset(x, y)]),
  ]);

  Widget bare(Widget child) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: SizedBox(width: 500, child: child)),
    ),
  );

  testWidgets('the sheet grows by a page and keeps it while erasing', (
    tester,
  ) async {
    Future<double> height(Drawing drawing) async {
      await tester.pumpWidget(
        bare(DrawingCanvas(drawing: drawing, onChanged: (_) {})),
      );
      await tester.pumpAndSettle();
      return tester.getSize(sheet()).height;
    }

    final start = await height(dot(500, 100));
    expect(await height(dot(500, 400)), start);

    // A stroke near the bottom adds a whole page, not just what it needs.
    final grown = await height(dot(500, 600));
    expect(grown, greaterThan(start + 200));
    expect(await height(dot(500, 620)), grown);

    // Erasing the low stroke leaves the page where it is.
    expect(await height(Drawing.empty), grown);
  });

  testWidgets('a card preview keeps its scale wherever a stroke lands', (
    tester,
  ) async {
    /// The slice of the sheet the card shows.
    Future<Rect?> preview(Drawing drawing) async {
      await tester.pumpWidget(bare(DrawingPreview(drawing: drawing)));
      final paint = tester.widget<CustomPaint>(sheet());
      return (paint.painter! as DrawingPainter).viewport;
    }

    final left = await preview(dot(100, 100));
    final right = await preview(dot(900, 100));
    expect(right, left);

    // A second stroke beside the first does not zoom the card out.
    final both = await preview(
      Drawing([
        Stroke(width: 8, points: const [Offset(100, 100)]),
        Stroke(width: 8, points: const [Offset(900, 100)]),
      ]),
    );
    expect(both, left);
  });
}
