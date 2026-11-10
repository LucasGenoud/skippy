import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../theme.dart';

/// Paints [pattern] behind [child], in the quiet ink every pattern shares.
/// A plain note gets [child] back untouched, so it costs nothing.
class NotePatternBackground extends StatelessWidget {
  final NotePattern pattern;
  final Widget child;

  const NotePatternBackground({
    super.key,
    required this.pattern,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (pattern == NotePattern.none) {
      return child;
    }

    final ink = notePatternInk(Theme.of(context).colorScheme);
    return CustomPaint(
      painter: _NotePatternPainter(pattern, ink),
      child: child,
    );
  }
}

/// The patterns themselves. Spacing follows a line of body text, so ruled
/// lines and grid cells sit at a handwriting scale.
class _NotePatternPainter extends CustomPainter {
  final NotePattern pattern;
  final Color ink;

  const _NotePatternPainter(this.pattern, this.ink);

  static const _cell = 20.0;
  static const _ruled = 26.0;
  static const _dotRadius = 1.3;
  static const _stroke = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ink
      ..strokeWidth = _stroke;

    switch (pattern) {
      case NotePattern.none:
        return;
      case NotePattern.dots:
        for (var y = _cell / 2; y < size.height; y += _cell) {
          for (var x = _cell / 2; x < size.width; x += _cell) {
            canvas.drawCircle(Offset(x, y), _dotRadius, paint);
          }
        }
      case NotePattern.grid:
        for (var x = _cell; x < size.width; x += _cell) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = _cell; y < size.height; y += _cell) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case NotePattern.lines:
        for (var y = _ruled; y < size.height; y += _ruled) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case NotePattern.diagonal:
        // Each stroke runs from the top or left edge down to the right,
        // starting far enough left that the corner is covered too.
        final reach = size.width + size.height;
        for (var start = -size.height; start < reach; start += _cell / 1.5) {
          canvas.drawLine(
            Offset(start, 0),
            Offset(start + size.height, size.height),
            paint,
          );
        }
      case NotePattern.checks:
        final fill = Paint()..color = ink.withValues(alpha: ink.a * 0.6);
        final columns = (size.width / _cell).ceil();
        final rows = (size.height / _cell).ceil();
        for (var row = 0; row < rows; row++) {
          for (var column = row % 2; column < columns; column += 2) {
            final cell = Rect.fromLTWH(
              column * _cell,
              row * _cell,
              _cell,
              _cell,
            );
            canvas.drawRect(
              Rect.fromLTRB(
                cell.left,
                cell.top,
                math.min(cell.right, size.width),
                math.min(cell.bottom, size.height),
              ),
              fill,
            );
          }
        }
    }
  }

  @override
  bool shouldRepaint(_NotePatternPainter old) =>
      old.pattern != pattern || old.ink != ink;
}
