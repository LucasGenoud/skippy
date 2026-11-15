import 'dart:math' as math;
import 'dart:ui' as ui;

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

/// The picture that stands for a motif pattern in a picker, where a 48px
/// tile would show only a stray corner of the scatter. Null for textures.
IconData? notePatternIcon(NotePattern pattern) =>
    _motifs[pattern]?.glyphs.first;

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

    if (_motifs[pattern] case final motif?) {
      _paintMotif(canvas, size, motif);
      return;
    }

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
      default:
        return;
    }
  }

  /// Repeats the motif's tile across [size]. The tile is recorded once per
  /// pattern and ink, so a card replays a picture instead of laying out
  /// glyphs on every paint.
  void _paintMotif(Canvas canvas, Size size, _Motif motif) {
    final tile = _motifTile(motif);
    const span = _Motif.cell * _Motif.cellsPerTile;
    for (var y = 0.0; y < size.height; y += span) {
      for (var x = 0.0; x < size.width; x += span) {
        canvas.save();
        canvas.translate(x, y);
        canvas.drawPicture(tile);
        canvas.restore();
      }
    }
  }

  ui.Picture _motifTile(_Motif motif) {
    final key = (pattern, ink.toARGB32());
    if (_tiles[key] case final tile?) {
      return tile;
    }

    // Inks change only with theme and accent; a cap keeps a long session
    // of accent changes from holding every tile it ever drew.
    if (_tiles.length >= _maxTiles) {
      _tiles.clear();
    }

    final tile = motif.record(ink.withValues(alpha: ink.a * _motifInkScale));
    _tiles[key] = tile;
    return tile;
  }

  static final _tiles = <(NotePattern, int), ui.Picture>{};
  static const _maxTiles = 48;

  /// Filled glyphs carry more ink than a hairline, so they draw lighter to
  /// sit at the same visual weight as the textures.
  static const _motifInkScale = 0.8;

  @override
  bool shouldRepaint(_NotePatternPainter old) =>
      old.pattern != pattern || old.ink != ink;
}

/// A scatter of small pictures: [glyphs] cycle across a staggered grid,
/// each turned to [tilt] give or take [sway] and slightly resized, so the
/// tile does not read as a stamp.
class _Motif {
  final List<IconData> glyphs;

  /// Base rotation in degrees, for glyphs with a direction of travel.
  final double tilt;

  /// Random rotation either side of [tilt], in degrees.
  final double sway;

  /// Seeds the scatter, so every motif lays out differently but stably.
  final int seed;

  const _Motif(this.glyphs, {this.tilt = 0, this.sway = 15, this.seed = 1});

  static const cell = 36.0;
  static const cellsPerTile = 4;
  static const _glyphSize = 15.0;
  static const _jitter = 4.0;
  static const _minScale = 0.85;
  static const _scaleRange = 0.3;

  ui.Picture record(Color ink) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final random = math.Random(seed);
    final painters = [
      for (final glyph in glyphs)
        TextPainter(
          text: TextSpan(
            text: String.fromCharCode(glyph.codePoint),
            style: TextStyle(
              fontFamily: glyph.fontFamily,
              package: glyph.fontPackage,
              fontSize: _glyphSize,
              height: 1,
              color: ink,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];

    // Odd rows shift half a cell, like bricks; with an even row count the
    // shift still lines up across tile seams.
    for (var row = 0; row < cellsPerTile; row++) {
      final shift = row.isOdd ? cell / 2 : 0.0;
      for (var column = 0; column < cellsPerTile; column++) {
        final glyph =
            painters[(row * cellsPerTile + column + row) % painters.length];
        final center = Offset(
          column * cell + cell / 2 + shift + _offset(random),
          row * cell + cell / 2 + _offset(random),
        );
        final turn =
            (tilt + (random.nextDouble() * 2 - 1) * sway) * math.pi / 180;
        final scale = _minScale + random.nextDouble() * _scaleRange;

        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(turn);
        canvas.scale(scale);
        glyph.paint(canvas, Offset(-glyph.width / 2, -glyph.height / 2));
        canvas.restore();
      }
    }

    for (final painter in painters) {
      painter.dispose();
    }
    return recorder.endRecording();
  }

  static double _offset(math.Random random) =>
      (random.nextDouble() * 2 - 1) * _jitter;
}

const _motifs = <NotePattern, _Motif>{
  NotePattern.airplanes: _Motif([Icons.flight], tilt: 45, sway: 8, seed: 3),
  NotePattern.cars: _Motif(
    [Icons.directions_car, Icons.airport_shuttle],
    sway: 6,
    seed: 5,
  ),
  NotePattern.notes: _Motif(
    [Icons.sticky_note_2, Icons.push_pin, Icons.edit],
    sway: 20,
    seed: 7,
  ),
  NotePattern.ideas: _Motif(
    [Icons.lightbulb, Icons.auto_awesome],
    sway: 18,
    seed: 11,
  ),
  NotePattern.hearts: _Motif([Icons.favorite], sway: 22, seed: 13),
  NotePattern.stars: _Motif(
    [Icons.star, Icons.auto_awesome],
    sway: 30,
    seed: 17,
  ),
  NotePattern.coffee: _Motif([Icons.coffee, Icons.cookie], sway: 15, seed: 19),
  NotePattern.leaves: _Motif(
    [Icons.eco, Icons.local_florist, Icons.spa],
    sway: 35,
    seed: 23,
  ),
  NotePattern.weather: _Motif(
    [Icons.wb_sunny, Icons.cloud, Icons.water_drop],
    sway: 10,
    seed: 29,
  ),
  NotePattern.music: _Motif(
    [Icons.music_note, Icons.headphones],
    sway: 15,
    seed: 31,
  ),
  NotePattern.paws: _Motif([Icons.pets], sway: 30, seed: 37),
  NotePattern.space: _Motif(
    [Icons.rocket_launch, Icons.public, Icons.star],
    sway: 20,
    seed: 41,
  ),
  NotePattern.sea: _Motif(
    [Icons.sailing, Icons.anchor, Icons.waves],
    sway: 10,
    seed: 43,
  ),
  NotePattern.food: _Motif(
    [Icons.local_pizza, Icons.icecream, Icons.cake],
    sway: 20,
    seed: 47,
  ),
};
