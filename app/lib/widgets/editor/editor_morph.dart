import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme.dart';
import '../../util/motion.dart';

/// The desktop half of the card→editor container transform: the modal grows out
/// of the card (or row) that opened it and shrinks back into it on close,
/// mirroring the fullscreen `NoteZoomRoute` morph phones get.
///
/// The visible box runs from the source's bounds to the dialog's. The dialog
/// is scaled to the box's width and cut off at its height:
///
/// ```text
///   t = 0    +==== reminder row ====+    box = source
///   t = 1       +---------------+        box = dialog
///               |    editor     |        scale = box.width / dialog.width
///               +---------------+        clip  = box.height / scale
/// ```
///
/// Scaling the whole dialog by width alone would leave a wide, short source (a
/// reminder row, a list-mode card) under a full-height dialog that slides to
/// it instead of shrinking into it. The surface reaches full opacity early
/// on, so the growing note reads as one opaque object leaving the grid
/// instead of a fade.
class EditorMorph extends StatelessWidget {
  final Animation<double> animation;

  /// Global bounds of the widget the editor is growing out of.
  final Rect source;

  final Widget child;

  const EditorMorph({
    super.key,
    required this.animation,
    required this.source,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        // Emphasized on the way out of the card, calmer on the way back in,
        // easing into the card rather than arriving at full speed.
        final curve = animation.status == AnimationStatus.reverse
            ? Motion.standard.flipped
            : Motion.emphasized;
        final t = curve.transform(animation.value.clamp(0.0, 1.0));
        return _MorphBox(
          source: source,
          progress: t,
          child: Opacity(opacity: (t * 4).clamp(0.0, 1.0), child: child),
        );
      },
    );
  }
}

/// Paints its child through [EditorMorph]'s box. The dialog keeps its
/// final layout throughout: it hugs its content, so its size is only known
/// after layout, and laying the editor out again on every frame of a 250ms
/// transition is exactly the kind of work that makes a morph stutter.
class _MorphBox extends SingleChildRenderObjectWidget {
  final Rect source;
  final double progress;

  const _MorphBox({
    required this.source,
    required this.progress,
    required super.child,
  });

  @override
  _RenderMorphBox createRenderObject(BuildContext context) =>
      _RenderMorphBox(source: source, progress: progress);

  @override
  void updateRenderObject(BuildContext context, _RenderMorphBox renderObject) {
    renderObject
      ..source = source
      ..progress = progress;
  }
}

class _RenderMorphBox extends RenderProxyBox {
  _RenderMorphBox({required this._source, required this._progress});

  /// In global coordinates, like `morphSourceRect` measures it.
  Rect _source;
  set source(Rect value) {
    if (value == _source) {
      return;
    }
    _source = value;
    markNeedsPaint();
  }

  double _progress;
  set progress(double value) {
    if (value == _progress) {
      return;
    }
    _progress = value;
    markNeedsPaint();
  }

  final LayerHandle<ClipRRectLayer> _clip = LayerHandle();

  bool get _resting => _progress >= 1 || size.isEmpty;

  /// Where the box is now, in this dialog's coordinates.
  Rect get _box {
    final toLocal = Matrix4.tryInvert(getTransformTo(null));
    if (toLocal == null) {
      return Offset.zero & size;
    }
    final source = MatrixUtils.transformRect(toLocal, _source);
    return Rect.lerp(source, Offset.zero & size, _progress)!;
  }

  /// Maps the dialog onto [box], scaled to its width.
  Matrix4 _transformFor(Rect box) {
    final scale = box.width / size.width;
    return Matrix4.translationValues(box.left, box.top, 0)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_resting) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }

    final box = _box;
    final scale = box.width / size.width;
    // Radius and height are in the dialog's own, unscaled coordinates.
    final clip = RRect.fromLTRBR(
      0,
      0,
      size.width,
      box.height / scale,
      Radius.circular(kRadius / scale),
    );
    context.pushTransform(
      needsCompositing,
      offset,
      _transformFor(box),
      (context, offset) => _clip.layer = context.pushClipRRect(
        needsCompositing,
        offset,
        clip.outerRect,
        clip,
        super.paint,
        oldLayer: _clip.layer,
      ),
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_resting) {
      return super.hitTest(result, position: position);
    }

    final box = _box;
    if (!box.contains(position)) {
      return false;
    }
    return result.addWithPaintTransform(
      transform: _transformFor(box),
      position: position,
      hitTest: (result, position) => super.hitTest(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!_resting) {
      transform.multiply(_transformFor(_box));
    }
    super.applyPaintTransform(child, transform);
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
