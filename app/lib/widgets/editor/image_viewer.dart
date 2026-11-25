part of 'attachment_tiles.dart';

/// Shows a note's [images] full size over black, opening on [initial]. With
/// more than one, a swipe, the side arrows or the arrow keys step between
/// them; a zoomed picture holds still until it is zoomed back out.
Future<void> _showImageViewer(
  BuildContext context, {
  required List<Attachment> images,
  required String Function(Attachment) urlOf,
  int initial = 0,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close image',
  barrierColor: Colors.black,
  transitionDuration: const Duration(milliseconds: 180),
  transitionBuilder: (context, animation, secondaryAnimation, child) =>
      FadeTransition(
        opacity: animation.drive(CurveTween(curve: Motion.standard)),
        child: child,
      ),
  pageBuilder: (context, animation, secondaryAnimation) =>
      _ImageViewer(images: images, urlOf: urlOf, initial: initial),
);

class _ImageViewer extends StatefulWidget {
  final List<Attachment> images;
  final String Function(Attachment) urlOf;
  final int initial;

  const _ImageViewer({
    required this.images,
    required this.urlOf,
    required this.initial,
  });

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late int _index = widget.initial.clamp(0, widget.images.length - 1);
  late final PageController _pages = PageController(initialPage: _index);
  bool _zoomed = false;

  Attachment get _current => widget.images[_index];
  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < widget.images.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.images.length) {
      return;
    }

    if (Motion.reduced(context)) {
      _pages.jumpToPage(target);
      return;
    }

    _pages.animateToPage(
      target,
      duration: Motion.base,
      curve: Motion.emphasized,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _step(1);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final url = widget.urlOf(current);
    final several = widget.images.length > 1;
    return Scaffold(
      key: const Key('image-viewer'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(width: kSpaceLg),
                  if (several)
                    Text(
                      '${_index + 1} / ${widget.images.length}',
                      key: const Key('image-viewer-position'),
                      semanticsLabel:
                          'Image ${_index + 1} of ${widget.images.length}',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Colors.white70,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  const Spacer(),
                  if (_canCopy(current))
                    IconButton(
                      tooltip: 'Copy image',
                      color: Colors.white,
                      icon: const Icon(Icons.content_copy_outlined),
                      onPressed: () => _copyImage(url),
                    ),
                  IconButton(
                    tooltip: 'Download image',
                    color: Colors.white,
                    icon: const Icon(Icons.download_outlined),
                    onPressed: () => _downloadImage(current, url),
                  ),
                  IconButton(
                    tooltip: 'Close image',
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Expanded(
                child: Stack(
                  children: [
                    PageView.builder(
                      controller: _pages,
                      physics: _zoomed
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      itemCount: widget.images.length,
                      onPageChanged: (index) => setState(() {
                        _index = index;
                        _zoomed = false;
                      }),
                      itemBuilder: (context, index) => _ViewerPage(
                        key: ValueKey(widget.images[index].id),
                        attachment: widget.images[index],
                        url: widget.urlOf(widget.images[index]),
                        onZoom: (zoomed) {
                          if (zoomed != _zoomed) {
                            setState(() => _zoomed = zoomed);
                          }
                        },
                      ),
                    ),
                    if (several) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _StepButton(
                          icon: Icons.chevron_left,
                          tooltip: 'Previous image',
                          onPressed: _hasPrevious ? () => _step(-1) : null,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _StepButton(
                          icon: Icons.chevron_right,
                          tooltip: 'Next image',
                          onPressed: _hasNext ? () => _step(1) : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One picture in the viewer, zoomable; tells [onZoom] when it is zoomed in
/// so the pages hold still under a pan.
class _ViewerPage extends StatefulWidget {
  final Attachment attachment;
  final String url;
  final ValueChanged<bool> onZoom;

  const _ViewerPage({
    super.key,
    required this.attachment,
    required this.url,
    required this.onZoom,
  });

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  final TransformationController _transform = TransformationController();

  // Above this the picture counts as zoomed in.
  static const double _zoomedScale = 1.01;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Widget _picture() {
    final attachment = widget.attachment;
    if (isSvgAttachment(attachment)) {
      return SvgPicture.network(
        widget.url,
        key: Key('full-image-${attachment.id}'),
        fit: BoxFit.contain,
        placeholderBuilder: (_) =>
            const Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Image(
      key: Key('full-image-${attachment.id}'),
      image: AttachmentImage(attachmentId: attachment.id, url: widget.url),
      fit: BoxFit.contain,
      frameBuilder: Motion.fadeInFrame,
      errorBuilder: (context, error, stack) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white, size: 40),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 5,
      onInteractionEnd: (_) =>
          widget.onZoom(_transform.value.getMaxScaleOnAxis() > _zoomedScale),
      child: SizedBox.expand(child: _picture()),
    ),
  );
}

/// A side arrow in the viewer. Fades out at either end of the set instead of
/// leaving a control that does nothing.
class _StepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSpaceSm),
      child: IgnorePointer(
        ignoring: !enabled,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0,
          duration: Motion.fast,
          curve: Motion.standard,
          child: Material(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: kBorderRadius,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(_OverlayBar._inset),
              child: _OverlayAction(
                icon: icon,
                tooltip: tooltip,
                onPressed: onPressed ?? () {},
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
