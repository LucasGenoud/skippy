import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// Width of the space strokes are recorded in. A drawing is scaled to
/// whatever width shows it, so a sketch made on a phone fills a desktop card
/// the same way.
const double kDrawingWidth = 1000;

/// The shortest sheet a drawing starts as, in drawing units.
const double kDrawingMinHeight = 750;

/// The largest an encoded drawing may grow. Its content rides in the offline
/// cache, every version and every sync, so it is capped well below the
/// browser's storage quota.
const int kMaxDrawingChars = 256 * 1024;

const int _formatVersion = 1;

/// One pen stroke. [color] is an RGB value, or null for the ink colour, which
/// follows the theme so a sketch stays legible in dark mode.
class Stroke {
  final int? color;
  final double width;
  final List<Offset> points;

  const Stroke({this.color, required this.width, required this.points});

  /// Whether any part of the stroke passes within [radius] of [point].
  bool touches(Offset point, double radius) {
    final reach = radius + width / 2;
    if (points.length == 1) {
      return (points.first - point).distance <= reach;
    }
    for (var i = 1; i < points.length; i++) {
      if (_segmentDistance(point, points[i - 1], points[i]) <= reach) {
        return true;
      }
    }
    return false;
  }
}

/// A note's strokes, encoded into its `content`.
///
/// The wire shape is compact on purpose, since every stroke is stored again
/// in each version: `{"v":1,"s":[{"c":16711680,"w":8,"p":[x0,y0,dx1,dy1,...]}]}`,
/// with whole-unit coordinates after the first point stored as deltas.
class Drawing {
  final List<Stroke> strokes;

  const Drawing([this.strokes = const []]);

  static const empty = Drawing();

  bool get isEmpty => strokes.isEmpty;

  /// How far down the lowest stroke reaches, in drawing units.
  double get contentHeight {
    var bottom = 0.0;
    for (final stroke in strokes) {
      for (final p in stroke.points) {
        bottom = math.max(bottom, p.dy + stroke.width / 2);
      }
    }
    return bottom;
  }

  /// The smallest box holding every stroke, edges included, or
  /// [Rect.zero] for an empty drawing.
  Rect get bounds {
    Rect? box;
    for (final stroke in strokes) {
      for (final p in stroke.points) {
        final dot = Rect.fromCircle(center: p, radius: stroke.width / 2);
        box = box?.expandToInclude(dot) ?? dot;
      }
    }
    return box ?? Rect.zero;
  }

  Drawing add(Stroke stroke) => Drawing([...strokes, stroke]);

  /// Removes every stroke within [radius] of [point], or returns this same
  /// drawing when none is.
  Drawing eraseAt(Offset point, double radius) =>
      eraseAlong(point, point, radius);

  /// Removes every stroke within [radius] of the path from [from] to [to].
  /// A pointer reports in jumps, and a fast swipe would otherwise skip
  /// straight over a thin line.
  Drawing eraseAlong(Offset from, Offset to, double radius) {
    final steps = math.max(1, ((to - from).distance / radius).ceil());
    final probes = [
      for (var i = 0; i <= steps; i++) Offset.lerp(from, to, i / steps)!,
    ];
    final kept = [
      for (final s in strokes)
        if (!probes.any((p) => s.touches(p, radius))) s,
    ];
    return kept.length == strokes.length ? this : Drawing(kept);
  }

  /// The note content for this drawing. Empty for no strokes, so a blank
  /// sheet counts as an empty note and is discarded like one.
  String encode() {
    if (strokes.isEmpty) {
      return '';
    }
    return jsonEncode({
      'v': _formatVersion,
      's': [for (final s in strokes) _encodeStroke(s)],
    });
  }

  static final _parsed = <String, Drawing>{};
  static const _parsedCap = 64;

  /// Reads note content back into strokes. Anything unreadable is an empty
  /// drawing rather than an error, since content is written by clients.
  ///
  /// Cards repaint often and decode the same few drawings, so the last
  /// [_parsedCap] results are remembered.
  static Drawing parse(String content) {
    if (content.trim().isEmpty) {
      return empty;
    }
    final known = _parsed.remove(content);
    if (known != null) {
      _parsed[content] = known;
      return known;
    }

    final drawing = _decode(content);
    _parsed[content] = drawing;
    if (_parsed.length > _parsedCap) {
      _parsed.remove(_parsed.keys.first);
    }
    return drawing;
  }

  static Drawing _decode(String content) {
    try {
      final json = jsonDecode(content);
      if (json is! Map || json['s'] is! List) {
        return empty;
      }
      return Drawing([
        for (final raw in json['s'] as List) ?_decodeStroke(raw),
      ]);
    } on FormatException {
      return empty;
    }
  }
}

Map<String, Object> _encodeStroke(Stroke stroke) {
  final coords = <int>[];
  var last = (x: 0, y: 0);
  for (final p in stroke.points) {
    final x = p.dx.round();
    final y = p.dy.round();
    coords
      ..add(x - last.x)
      ..add(y - last.y);
    last = (x: x, y: y);
  }
  return {
    if (stroke.color != null) 'c': stroke.color!,
    'w': stroke.width.round(),
    'p': coords,
  };
}

Stroke? _decodeStroke(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final coords = raw['p'];
  final width = raw['w'];
  if (coords is! List || coords.length < 2 || width is! num) {
    return null;
  }

  final points = <Offset>[];
  var x = 0.0;
  var y = 0.0;
  for (var i = 0; i + 1 < coords.length; i += 2) {
    final dx = coords[i];
    final dy = coords[i + 1];
    if (dx is! num || dy is! num) {
      return null;
    }
    x += dx;
    y += dy;
    points.add(Offset(x, y));
  }
  final color = raw['c'];
  return Stroke(
    color: color is int ? color : null,
    width: width.toDouble(),
    points: points,
  );
}

/// [points] with the ones that add nothing to the line's shape dropped
/// (Ramer-Douglas-Peucker): a pen samples far more often than a stroke needs.
List<Offset> simplifyStroke(List<Offset> points, {double tolerance = 1}) {
  if (points.length < 3) {
    return points;
  }
  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;

  // An explicit stack rather than recursion: a long stroke has thousands of
  // samples.
  final spans = <(int, int)>[(0, points.length - 1)];
  while (spans.isNotEmpty) {
    final (first, last) = spans.removeLast();
    var farthest = -1;
    var distance = tolerance;
    for (var i = first + 1; i < last; i++) {
      final d = _segmentDistance(points[i], points[first], points[last]);
      if (d > distance) {
        distance = d;
        farthest = i;
      }
    }
    if (farthest < 0) {
      continue;
    }
    keep[farthest] = true;
    spans
      ..add((first, farthest))
      ..add((farthest, last));
  }
  return [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

double _segmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) {
    return (p - a).distance;
  }
  final ap = p - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}
