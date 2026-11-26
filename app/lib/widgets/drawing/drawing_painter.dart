import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/drawing.dart';

/// Paints [drawing] scaled from [kDrawingWidth] to the width it is given.
/// Shared by the editor's canvas and the card preview, so a sketch looks the
/// same in both.
class DrawingPainter extends CustomPainter {
  final Drawing drawing;

  /// The colour of strokes drawn in ink, which follows the theme.
  final Color ink;

  /// The part of the sheet to show, in drawing units, scaled to the width
  /// painted. Null shows the whole sheet from its top-left corner.
  final Rect? viewport;

  const DrawingPainter({
    required this.drawing,
    required this.ink,
    this.viewport,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final view = viewport;
    canvas.save();
    if (view == null) {
      canvas.scale(size.width / kDrawingWidth);
    } else {
      canvas.scale(size.width / view.width);
      canvas.translate(-view.left, -view.top);
    }
    for (final stroke in drawing.strokes) {
      paintStroke(canvas, stroke, ink);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DrawingPainter old) =>
      !identical(old.drawing, drawing) ||
      old.ink != ink ||
      old.viewport != viewport;
}

/// The live stroke under the pen, repainted on every sample without touching
/// the strokes already drawn.
class LiveStrokePainter extends CustomPainter {
  final ValueNotifier<Stroke?> stroke;
  final Color ink;

  LiveStrokePainter({required this.stroke, required this.ink})
    : super(repaint: stroke);

  @override
  void paint(Canvas canvas, Size size) {
    final live = stroke.value;
    if (live == null) {
      return;
    }
    canvas.save();
    canvas.scale(size.width / kDrawingWidth);
    paintStroke(canvas, live, ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(LiveStrokePainter old) =>
      old.stroke != stroke || old.ink != ink;
}

/// Draws one stroke in drawing units. The line runs through the midpoints
/// between samples with each sample as a control point, which smooths the
/// corners a pen's sampling rate leaves.
void paintStroke(Canvas canvas, Stroke stroke, Color ink) {
  final color = stroke.color == null ? ink : Color(0xFF000000 | stroke.color!);
  final points = stroke.points;
  if (points.length == 1) {
    canvas.drawCircle(points.first, stroke.width / 2, Paint()..color = color);
    return;
  }

  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length - 1; i++) {
    final mid = (points[i] + points[i + 1]) / 2;
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );
}

/// The tallest a card's preview grows, as a share of its width, so one long
/// sketch cannot take over a column.
const double _maxPreviewAspect = 1.25;

/// The shortest, so a single line still reads as a drawing.
const double _minPreviewAspect = 0.3;

/// Margin kept around the strokes on a card, in drawing units.
const double _previewMargin = 40;

/// The narrowest slice of the sheet a card shows, so a small doodle is
/// enlarged at most twice rather than blown up to fill the card.
const double _minPreviewWidth = kDrawingWidth / 2;

/// A drawing at card size, framed to its strokes: the blank sheet around a
/// sketch is cropped, and a tall one is cut at [_maxPreviewAspect].
class DrawingPreview extends StatelessWidget {
  final Drawing drawing;

  const DrawingPreview({super.key, required this.drawing});

  @override
  Widget build(BuildContext context) {
    final view = _frame(drawing.bounds.inflate(_previewMargin));
    return AspectRatio(
      aspectRatio: view.width / view.height,
      child: ClipRect(
        child: CustomPaint(
          painter: DrawingPainter(
            drawing: drawing,
            ink: Theme.of(context).colorScheme.onSurface,
            viewport: view,
          ),
        ),
      ),
    );
  }

  /// [content] widened to at least [_minPreviewWidth] around its centre and
  /// given a height within the preview's aspect bounds, top kept in place.
  static Rect _frame(Rect content) {
    final width = math.max(content.width, _minPreviewWidth);
    final height = content.height.clamp(
      width * _minPreviewAspect,
      width * _maxPreviewAspect,
    );
    final top = content.height < height
        ? content.center.dy - height / 2
        : content.top;
    return Rect.fromLTWH(content.center.dx - width / 2, top, width, height);
  }
}
