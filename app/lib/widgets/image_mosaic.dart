import 'package:flutter/widgets.dart';

import '../util/motion.dart';

/// Where a mosaic is drawn, which decides its gaps, caps and arrangement.
enum MosaicStyle { card, editor }

/// The most pictures a card shows; the last tile counts the rest.
const int kCardMosaicTiles = 4;

/// One arrangement: a rect per tile, in tile order, and the total height.
class MosaicFrame {
  final List<Rect> tiles;
  final double height;

  const MosaicFrame(this.tiles, this.height);
}

// Card: hairline gaps, so the pictures read as one block on the note.
const double _cardGap = 2;
const double _cardMaxHeight = 280;
const double _cardSingleEstimate = 160;

// Editor: separate rounded tiles, each with its own actions.
const double _editorGap = 8;
const double _editorMaxHeight = 320;
const double _editorSingleEstimate = 200;
const double _editorMaxTileHeight = 240;
const double _editorThreeColumnWidth = 520;

// A banner-shaped picture still gets a tile worth tapping.
const double _minSingleHeight = 48;

/// Arranges [count] tiles across [width].
///
/// Card, at most [kCardMosaicTiles] tiles:
///
/// ```text
///   1          2           3            4+
///   +------+   +---+---+   +-------+    +---+---+
///   |      |   |   |   |   |       |    |   |   |
///   |      |   |   |   |   +---+---+    +---+---+
///   +------+   +---+---+   |   |   |    |   |+N |
///                          +---+---+    +---+---+
/// ```
///
/// Editor: one picture at full width, more as a grid of equal tiles, three
/// across once the editor is wide enough.
///
/// A lone picture takes its own [leadAspect] (width / height) up to a cap, so
/// a landscape photo is not cropped into a square.
MosaicFrame mosaicLayout(
  MosaicStyle style, {
  required int count,
  required double width,
  double? leadAspect,
}) {
  if (count <= 0) {
    return const MosaicFrame([], 0);
  }

  return switch (style) {
    MosaicStyle.card => _cardLayout(count, width, leadAspect),
    MosaicStyle.editor => _editorLayout(count, width, leadAspect),
  };
}

double _singleHeight(
  double width,
  double? aspect, {
  required double estimate,
  required double max,
}) {
  final natural = aspect == null || aspect <= 0 ? estimate : width / aspect;
  return natural.clamp(_minSingleHeight, max);
}

MosaicFrame _cardLayout(int count, double width, double? leadAspect) {
  const gap = _cardGap;
  final half = (width - gap) / 2;

  if (count == 1) {
    final height = _singleHeight(
      width,
      leadAspect,
      estimate: _cardSingleEstimate,
      max: _cardMaxHeight,
    );
    return MosaicFrame([Rect.fromLTWH(0, 0, width, height)], height);
  }

  if (count == 2) {
    // Two portrait tiles, 4:5.
    final height = (half * 1.25).clamp(0.0, _cardMaxHeight);
    return MosaicFrame([
      Rect.fromLTWH(0, 0, half, height),
      Rect.fromLTWH(half + gap, 0, half, height),
    ], height);
  }

  if (count == 3) {
    // One wide picture over two small ones. Stacking suits the narrow
    // columns cards sit in better than a tall picture beside two slivers.
    var top = width * 0.5;
    var bottom = half * 0.75;
    final natural = top + gap + bottom;
    if (natural > _cardMaxHeight) {
      final scale = (_cardMaxHeight - gap) / (top + bottom);
      top *= scale;
      bottom *= scale;
    }
    final lower = top + gap;
    return MosaicFrame([
      Rect.fromLTWH(0, 0, width, top),
      Rect.fromLTWH(0, lower, half, bottom),
      Rect.fromLTWH(half + gap, lower, half, bottom),
    ], lower + bottom);
  }

  final side = half.clamp(0.0, (_cardMaxHeight - gap) / 2);
  final lower = side + gap;
  return MosaicFrame([
    Rect.fromLTWH(0, 0, half, side),
    Rect.fromLTWH(half + gap, 0, half, side),
    Rect.fromLTWH(0, lower, half, side),
    Rect.fromLTWH(half + gap, lower, half, side),
  ], lower + side);
}

MosaicFrame _editorLayout(int count, double width, double? leadAspect) {
  const gap = _editorGap;

  if (count == 1) {
    final height = _singleHeight(
      width,
      leadAspect,
      estimate: _editorSingleEstimate,
      max: _editorMaxHeight,
    );
    return MosaicFrame([Rect.fromLTWH(0, 0, width, height)], height);
  }

  final columns = count > 2 && width >= _editorThreeColumnWidth ? 3 : 2;
  final tileWidth = (width - gap * (columns - 1)) / columns;
  final tileHeight = tileWidth.clamp(0.0, _editorMaxTileHeight);
  final tiles = <Rect>[
    for (var i = 0; i < count; i++)
      Rect.fromLTWH(
        (i % columns) * (tileWidth + gap),
        (i ~/ columns) * (tileHeight + gap),
        tileWidth,
        tileHeight,
      ),
  ];
  final rows = (count + columns - 1) ~/ columns;
  return MosaicFrame(tiles, rows * tileHeight + (rows - 1) * gap);
}

/// Lays keyed [tiles] out with [mosaicLayout] and animates every change:
/// tiles that stay glide to their new rects, new ones fade in where they
/// land, removed ones fade out where they were, and the height follows.
/// What is there on the first build shows at once.
///
/// [leadImage] is read only for its size, and only while a single tile shows,
/// so that tile can take the picture's own shape.
class ImageMosaic extends StatefulWidget {
  final MosaicStyle style;
  final List<Widget> tiles;
  final ImageProvider? leadImage;

  const ImageMosaic({
    super.key,
    required this.style,
    required this.tiles,
    this.leadImage,
  });

  @override
  State<ImageMosaic> createState() => _ImageMosaicState();
}

class _ImageMosaicState extends State<ImageMosaic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: Motion.base,
    value: 1,
  )..addStatusListener(_onMotionStatus);
  late final Animation<double> _eased = CurvedAnimation(
    parent: _motion,
    curve: Motion.emphasized,
  );

  // Where every tile was at the last layout, so a change starts from what is
  // on screen, even halfway through another change.
  final _MosaicSnapshot _last = _MosaicSnapshot();
  Map<Key, Rect> _fromRects = const {};
  double? _fromHeight;

  final Map<Key, Widget> _leaving = {};
  final Set<Key> _entering = {};

  double? _aspect;
  bool _asking = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  List<Key> get _keys => [for (final tile in widget.tiles) tile.key!];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _probeAspect();
  }

  @override
  void didUpdateWidget(ImageMosaic old) {
    super.didUpdateWidget(old);
    final before = [for (final tile in old.tiles) tile.key!];
    final after = _keys;
    if (!_sameOrder(before, after) || old.style != widget.style) {
      final kept = after.toSet();
      for (final tile in old.tiles) {
        if (!kept.contains(tile.key)) {
          _leaving[tile.key!] = tile;
        }
      }
      for (final key in after) {
        _leaving.remove(key);
      }
      _entering
        ..removeWhere((key) => !kept.contains(key))
        ..addAll(after.where((key) => !before.contains(key)));
      _move();
    }
    _probeAspect();
  }

  static bool _sameOrder(List<Key> a, List<Key> b) {
    if (a.length != b.length) {
      return false;
    }

    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// Starts a transition from the rects on screen to the current layout.
  void _move() {
    if (_last.rects.isEmpty || Motion.reduced(context)) {
      _settle();
      return;
    }

    _fromRects = Map.of(_last.rects);
    _fromHeight = _last.height;
    _motion.forward(from: 0);
  }

  void _settle() {
    _leaving.clear();
    _entering.clear();
    _fromRects = const {};
    _fromHeight = null;
    _motion.value = 1;
  }

  void _onMotionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) {
      return;
    }

    if (_leaving.isEmpty && _entering.isEmpty) {
      return;
    }

    setState(() {
      _leaving.clear();
      _entering.clear();
    });
  }

  void _probeAspect() {
    final provider = widget.tiles.length == 1 ? widget.leadImage : null;
    if (provider == null) {
      _detach();
      _stream = null;
      return;
    }

    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) {
      return;
    }

    _detach();
    _listener = ImageStreamListener((info, _) {
      final width = info.image.width.toDouble();
      final height = info.image.height.toDouble();
      if (!mounted || width <= 0 || height <= 0) {
        return;
      }

      final aspect = width / height;
      if (aspect == _aspect) {
        return;
      }

      // A cached picture answers while it is being asked, inside this
      // build; one still loading answers later, and its tile then eases to
      // the real shape.
      if (_asking) {
        _aspect = aspect;
        return;
      }

      setState(() {
        _aspect = aspect;
        _move();
      });
    }, onError: (_, _) {});
    _stream = stream;
    _asking = true;
    stream.addListener(_listener!);
    _asking = false;
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
  }

  @override
  void dispose() {
    _detach();
    _motion.dispose();
    super.dispose();
  }

  Animation<double> _opacityOf(Key key) {
    if (_leaving.containsKey(key)) {
      return ReverseAnimation(_eased);
    }

    if (_entering.contains(key)) {
      return _eased;
    }

    return kAlwaysCompleteAnimation;
  }

  @override
  Widget build(BuildContext context) {
    // Leaving tiles paint first, under the ones taking their place.
    final children = [
      for (final MapEntry(:key, value: tile) in _leaving.entries)
        _place(key, tile),
      for (final tile in widget.tiles) _place(tile.key!, tile),
    ];
    return ClipRect(
      child: CustomMultiChildLayout(
        delegate: _MosaicDelegate(
          style: widget.style,
          keys: _keys,
          leaving: _leaving.keys.toList(),
          leadAspect: _aspect,
          from: _fromRects,
          fromHeight: _fromHeight,
          progress: _eased,
          snapshot: _last,
        ),
        children: children,
      ),
    );
  }

  // The slot keeps the tile's element across reorders; its key wraps the
  // tile's so the two never look alike to a key lookup.
  Widget _place(Key key, Widget tile) => LayoutId(
    key: ValueKey<Key>(key),
    id: key,
    child: FadeTransition(opacity: _opacityOf(key), child: tile),
  );
}

class _MosaicSnapshot {
  Map<Key, Rect> rects = const {};
  double height = 0;
}

class _MosaicDelegate extends MultiChildLayoutDelegate {
  final MosaicStyle style;
  final List<Key> keys;
  final List<Key> leaving;
  final double? leadAspect;
  final Map<Key, Rect> from;
  final double? fromHeight;
  final Animation<double> progress;
  final _MosaicSnapshot snapshot;

  _MosaicDelegate({
    required this.style,
    required this.keys,
    required this.leaving,
    required this.leadAspect,
    required this.from,
    required this.fromHeight,
    required this.progress,
    required this.snapshot,
  }) : super(relayout: progress);

  // Only reached in an unbounded parent, which neither the card nor the
  // editor is.
  static const double _fallbackWidth = 320;

  MosaicFrame _target(double width) => mosaicLayout(
    style,
    count: keys.length,
    width: width,
    leadAspect: leadAspect,
  );

  double _widthOf(BoxConstraints constraints) =>
      constraints.hasBoundedWidth ? constraints.maxWidth : _fallbackWidth;

  @override
  Size getSize(BoxConstraints constraints) {
    final width = _widthOf(constraints);
    final target = _target(width).height;
    final start = fromHeight ?? target;
    final height = start + (target - start) * progress.value;
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout(Size size) {
    final target = _target(size.width);
    final t = progress.value;
    final placed = <Key, Rect>{};

    // Every child must be laid out; one that left before it was ever placed
    // takes no room.
    for (final key in leaving) {
      _put(key, from[key] ?? Rect.zero, placed);
    }

    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final end = target.tiles[i];
      final start = from[key];
      final rect = start == null ? end : Rect.lerp(start, end, t)!;
      _put(key, rect, placed);
    }

    snapshot
      ..rects = placed
      ..height = size.height;
  }

  void _put(Key key, Rect rect, Map<Key, Rect> placed) {
    layoutChild(key, BoxConstraints.tight(rect.size));
    positionChild(key, rect.topLeft);
    placed[key] = rect;
  }

  @override
  bool shouldRelayout(_MosaicDelegate old) => true;
}
