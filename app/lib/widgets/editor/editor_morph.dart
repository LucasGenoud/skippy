import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme.dart';
import '../../util/motion.dart';

/// Global-coordinate bounds of the widget that [context] belongs to; null when
/// it has no laid-out render box.
Rect? _rectOf(BuildContext context) {
  if (!context.mounted) {
    return null;
  }
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

/// What the desktop editor grows out of and shrinks back into: a card, a
/// reminder row, a button.
class MorphSource {
  final BuildContext _context;

  /// The source's face, drawn over the growing surface while it fades out.
  /// Built in the editor's route, so it can follow the note as it changes.
  final WidgetBuilder? face;

  /// Hides the source while the editor stands in for it, so the note leaves
  /// its slot instead of being copied out of it.
  final ValueChanged<bool>? onHidden;

  /// Corner radius the source has.
  final double radius;

  const MorphSource(
    this._context, {
    this.face,
    this.onHidden,
    this.radius = kCardRadius,
  });

  /// Where the source is now, or null once it has left the tree.
  Rect? get rect => _rectOf(_context);
}

/// The desktop half of the card→editor container transform, mirroring the
/// fullscreen `NoteZoomRoute` morph phones get: the card's surface grows into
/// the dialog at full size, nothing scaled, while the card's face fades out
/// and the editor fades in over it.
///
/// ```text
///   0.0   +== card ==+          surface = card, face shown
///   0.3   +===== surface =====+ face gone, editor starting to show
///   0.75  |                   | editor fully shown
///   1.0   +------ dialog -----+
/// ```
///
/// The editor keeps its final layout, pinned by its text column to the
/// surface's top-left corner, and the surface uncovers more of it as it grows.
/// Closing runs the same way back, into wherever the source is by then: a
/// card that grew while the note was edited is measured again.
class EditorMorph extends StatefulWidget {
  final Animation<double> animation;
  final MorphSource source;

  /// The surface's colour, the same as the editor's own background.
  final Color color;

  /// Corner radius the dialog has at rest.
  final double endRadius;

  /// Widest the editor's text column gets, centred in a wider dialog. The
  /// column's left edge, not the dialog's, starts on the source's.
  final double contentWidth;

  final Widget child;

  const EditorMorph({
    super.key,
    required this.animation,
    required this.source,
    required this.color,
    required this.endRadius,
    required this.contentWidth,
    required this.child,
  });

  /// The source's face is gone by this share of the morph.
  static const Interval _faceFade = Interval(0, 0.3);

  /// The editor fades in over this share, after the face.
  static const Interval _editorFade = Interval(0.3, 0.75);

  @override
  State<EditorMorph> createState() => _EditorMorphState();
}

class _EditorMorphState extends State<EditorMorph> {
  late Rect? _source = widget.source.rect;
  Widget? _face;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    // The tree is locked while this unmounts; show the source after it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _lend(false));
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    switch (status) {
      // The source may have moved or grown while the note was open.
      case AnimationStatus.reverse:
        setState(() => _source = widget.source.rect ?? _source);
      case AnimationStatus.dismissed:
        _lend(false);
      case AnimationStatus.forward:
      case AnimationStatus.completed:
        break;
    }
  }

  void _lend(bool hidden) => widget.source.onHidden?.call(hidden);

  /// Built once: the same widget every frame lets it skip rebuilding.
  Widget? _faceOf(BuildContext context) {
    final face = widget.source.face;
    if (face == null) {
      return null;
    }
    return _face ??= ExcludeSemantics(
      child: RepaintBoundary(child: Builder(builder: face)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source == null) {
      return widget.child;
    }

    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final value = widget.animation.value.clamp(0.0, 1.0);
        // Emphasized out of the card, calmer back into it, easing into the
        // card rather than arriving at full speed.
        final curve = widget.animation.status == AnimationStatus.reverse
            ? Motion.standard.flipped
            : Motion.emphasized;
        final t = curve.transform(value);
        return _MorphBox(
          source: source,
          progress: t,
          radius: lerpDouble(widget.source.radius, widget.endRadius, t)!,
          color: widget.color,
          contentWidth: widget.contentWidth,
          faceOpacity: 1 - EditorMorph._faceFade.transform(value),
          editorOpacity: EditorMorph._editorFade.transform(value),
          editor: widget.child,
          // Only while it can show: a mounted face would rebuild with every
          // edit made in the open note. Mounted again to close, it shows the
          // note as it now is.
          face: value < 1 || widget.animation.status == AnimationStatus.reverse
              ? _faceOf(context)
              : null,
        );
      },
    );
  }
}

enum _MorphSlot { editor, face }

/// Paints [EditorMorph]'s surface, face and editor. The dialog keeps its
/// final layout throughout: it hugs its content, so its size is only known
/// after layout, and laying the editor out again on every frame of a 250ms
/// transition is exactly the kind of work that makes a morph stutter.
class _MorphBox
    extends SlottedMultiChildRenderObjectWidget<_MorphSlot, RenderBox> {
  final Rect source;
  final double progress;
  final double radius;
  final Color color;
  final double contentWidth;
  final double faceOpacity;
  final double editorOpacity;
  final Widget editor;
  final Widget? face;

  const _MorphBox({
    required this.source,
    required this.progress,
    required this.radius,
    required this.color,
    required this.contentWidth,
    required this.faceOpacity,
    required this.editorOpacity,
    required this.editor,
    required this.face,
  });

  @override
  Iterable<_MorphSlot> get slots => _MorphSlot.values;

  @override
  Widget? childForSlot(_MorphSlot slot) => switch (slot) {
    _MorphSlot.editor => editor,
    _MorphSlot.face => face,
  };

  @override
  _RenderMorphBox createRenderObject(BuildContext context) => _RenderMorphBox()
    .._source = source
    .._progress = progress
    .._radius = radius
    .._color = color
    .._contentWidth = contentWidth
    .._faceOpacity = faceOpacity
    .._editorOpacity = editorOpacity;

  @override
  void updateRenderObject(BuildContext context, _RenderMorphBox renderObject) {
    renderObject
      ..source = source
      ..paintValues(
        progress: progress,
        radius: radius,
        color: color,
        contentWidth: contentWidth,
        faceOpacity: faceOpacity,
        editorOpacity: editorOpacity,
      );
  }
}

class _RenderMorphBox extends RenderBox
    with SlottedContainerRenderObjectMixin<_MorphSlot, RenderBox> {
  /// In global coordinates, like [_rectOf] measures it.
  late Rect _source;
  set source(Rect value) {
    if (value == _source) {
      return;
    }
    _source = value;
    // The face is laid out at the source's size.
    markNeedsLayout();
  }

  late double _progress;
  late double _radius;
  late Color _color;
  late double _contentWidth;
  late double _faceOpacity;
  late double _editorOpacity;

  void paintValues({
    required double progress,
    required double radius,
    required Color color,
    required double contentWidth,
    required double faceOpacity,
    required double editorOpacity,
  }) {
    if (progress == _progress &&
        radius == _radius &&
        color == _color &&
        contentWidth == _contentWidth &&
        faceOpacity == _faceOpacity &&
        editorOpacity == _editorOpacity) {
      return;
    }
    _progress = progress;
    _radius = radius;
    _color = color;
    _contentWidth = contentWidth;
    _faceOpacity = faceOpacity;
    _editorOpacity = editorOpacity;
    markNeedsPaint();
  }

  final LayerHandle<ClipRRectLayer> _clip = LayerHandle();
  final LayerHandle<OpacityLayer> _faceLayer = LayerHandle();
  final LayerHandle<OpacityLayer> _editorLayer = LayerHandle();

  RenderBox? get _editor => childForSlot(_MorphSlot.editor);
  RenderBox? get _face => childForSlot(_MorphSlot.face);

  bool get _resting => _progress >= 1 || size.isEmpty;

  /// Where the surface is now, in this dialog's coordinates.
  Rect get _box {
    final toLocal = Matrix4.tryInvert(getTransformTo(null));
    if (toLocal == null) {
      return Offset.zero & size;
    }
    final source = MatrixUtils.transformRect(toLocal, _source);
    return Rect.lerp(source, Offset.zero & size, _progress)!;
  }

  /// Where the editor's origin sits: its text column's corner on the
  /// surface's at first, its own by the end.
  Offset _editorShift(Rect box) {
    final column = ((size.width - _contentWidth) / 2).clamp(0.0, size.width);
    return box.topLeft - Offset(column * (1 - _progress), 0);
  }

  @override
  void performLayout() {
    final editor = _editor;
    if (editor == null) {
      size = constraints.smallest;
      return;
    }
    editor.layout(constraints, parentUsesSize: true);
    size = editor.size;
    _face?.layout(BoxConstraints.tight(_source.size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final editor = _editor;
    if (editor == null) {
      return;
    }
    if (_resting) {
      _clip.layer = null;
      _faceLayer.layer = null;
      _editorLayer.layer = null;
      context.paintChild(editor, offset);
      return;
    }

    final box = _box;
    final surface = RRect.fromRectAndRadius(box, Radius.circular(_radius));
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      box,
      surface,
      (context, offset) {
        context.canvas.drawRRect(
          surface.shift(offset),
          Paint()..color = _color,
        );
        _faceLayer.layer = _paintFaded(
          context,
          _face,
          offset + box.topLeft,
          _faceOpacity,
          _faceLayer.layer,
        );
        _editorLayer.layer = _paintFaded(
          context,
          editor,
          offset + _editorShift(box),
          _editorOpacity,
          _editorLayer.layer,
        );
      },
      oldLayer: _clip.layer,
    );
  }

  OpacityLayer? _paintFaded(
    PaintingContext context,
    RenderBox? child,
    Offset offset,
    double opacity,
    OpacityLayer? oldLayer,
  ) {
    if (child == null || opacity <= 0) {
      return null;
    }
    return context.pushOpacity(
      offset,
      (opacity * 255).round(),
      (context, offset) => context.paintChild(child, offset),
      oldLayer: oldLayer,
    );
  }

  @override
  bool hitTestSelf(Offset position) => !_resting && _box.contains(position);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final editor = _editor;
    if (editor == null) {
      return false;
    }
    if (_resting) {
      return editor.hitTest(result, position: position);
    }

    // Mid-morph the surface takes the pointer itself: nothing in it is
    // where it will be.
    if (!hitTestSelf(position)) {
      return false;
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_resting) {
      return;
    }
    final box = _box;
    final shift = child == _editor ? _editorShift(box) : box.topLeft;
    transform.translateByDouble(shift.dx, shift.dy, 0, 1);
  }

  @override
  void dispose() {
    _clip.layer = null;
    _faceLayer.layer = null;
    _editorLayer.layer = null;
    super.dispose();
  }
}
