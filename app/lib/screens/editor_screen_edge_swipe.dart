part of 'editor_screen.dart';

/// The edge swipe that dismisses a full-screen editor, tracking the finger
/// through the zoom route when there is one.
extension _EditorEdgeSwipe on _EditorScreenState {
  void _onEdgeSwipeStart(DragStartDetails details) {
    _edgeSwipeDistance = 0;
    _edgeSwipeOrigin = details.globalPosition;
    _edgeSwipeDismissed = false;
    _zoomRoute?.startDrag(details.globalPosition);
  }

  void _onEdgeSwipeUpdate(DragUpdateDetails details) {
    _edgeSwipeDistance += details.delta.dx;

    // In a zoom route the note follows the finger and the release decides.
    final zoom = _zoomRoute;
    if (zoom != null) {
      zoom.updateDrag(details.globalPosition - _edgeSwipeOrigin);
      return;
    }

    if (_edgeSwipeDistance >= _edgeDismissDistance) {
      _dismissFromEdgeSwipe();
    }
  }

  void _onEdgeSwipeEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dx;
    final zoom = _zoomRoute;
    if (zoom != null) {
      final flungBack = velocity <= -_edgeDismissFlingVelocity;
      final far = _edgeSwipeDistance >= _edgeDismissDistance;
      zoom.endDrag(
        dismiss: velocity >= _edgeDismissFlingVelocity || (far && !flungBack),
        velocity: details.velocity.pixelsPerSecond,
      );
      _resetEdgeSwipe();
      return;
    }

    if (velocity >= _edgeDismissFlingVelocity) {
      _dismissFromEdgeSwipe();
    }
    _resetEdgeSwipe();
  }

  void _onEdgeSwipeCancel() {
    _zoomRoute?.endDrag(dismiss: false);
    _resetEdgeSwipe();
  }

  void _dismissFromEdgeSwipe() {
    if (_edgeSwipeDismissed) return;
    _edgeSwipeDismissed = true;
    dismissKeyboard();
    Navigator.of(context).maybePop();
  }

  void _resetEdgeSwipe() {
    _edgeSwipeDistance = 0;
  }
}
