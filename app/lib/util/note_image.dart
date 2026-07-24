import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/note.dart';
import 'attachment_image.dart';

/// Renders a note image attachment.
///
/// Two things the plain [Image] widget can't do on its own:
///  * **Vector formats.** SVG bytes aren't a raster the image decoder can
///    handle, so those attachments render through [SvgPicture] instead.
///  * **Aspect-aware sizing.** Rather than force every image into a fixed
///    letterbox, the tile grows to the image's own aspect ratio (at the
///    available width) up to [maxHeight] — so as much of the picture shows as
///    fits before it starts to crop. Anything taller than the cap crops from
///    the bottom (top-aligned cover); shorter images show in full.
class NoteImage extends StatelessWidget {
  final Attachment attachment;
  final String url;

  /// The tallest the image is allowed to render before it crops.
  final double maxHeight;

  const NoteImage({
    super.key,
    required this.attachment,
    required this.url,
    this.maxHeight = 160,
  });

  bool get _isSvg =>
      attachment.mime == 'image/svg+xml' ||
      attachment.mime.toLowerCase().contains('svg');

  Widget _error(BuildContext context, double height) => Container(
    height: height,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: const Icon(Icons.broken_image_outlined),
  );

  @override
  Widget build(BuildContext context) {
    if (_isSvg) {
      // Vector: scale the whole drawing to the column width and let its own
      // aspect ratio drive the height, capped so a tall SVG can't run away.
      // A concrete width (not double.infinity) is required — infinity makes
      // flutter_svg resolve the height to infinity, forcing the full cap.
      return ClipRect(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: LayoutBuilder(
            builder: (context, constraints) => SvgPicture.network(
              url,
              width: constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : null,
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              placeholderBuilder: (context) => Container(
                height: maxHeight,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
        ),
      );
    }
    return _RasterNoteImage(
      attachment: attachment,
      url: url,
      maxHeight: maxHeight,
      errorBuilder: _error,
    );
  }
}

/// The raster path: resolves the image's intrinsic aspect ratio so the tile
/// can size itself to the picture instead of a fixed box.
class _RasterNoteImage extends StatefulWidget {
  final Attachment attachment;
  final String url;
  final double maxHeight;
  final Widget Function(BuildContext, double height) errorBuilder;

  const _RasterNoteImage({
    required this.attachment,
    required this.url,
    required this.maxHeight,
    required this.errorBuilder,
  });

  @override
  State<_RasterNoteImage> createState() => _RasterNoteImageState();
}

class _RasterNoteImageState extends State<_RasterNoteImage> {
  double? _aspect; // width / height of the decoded image
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _failed = false;

  // A neutral shape while dimensions are unknown, so the masonry has something
  // to measure before the bytes land.
  static const double _estimatedHeight = 160;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspect();
  }

  @override
  void didUpdateWidget(_RasterNoteImage old) {
    super.didUpdateWidget(old);
    if (old.attachment.id != widget.attachment.id || old.url != widget.url) {
      _aspect = null;
      _failed = false;
      _resolveAspect();
    }
  }

  void _resolveAspect() {
    // A small, unbucketed probe just to learn the aspect ratio; the visible
    // pixels are decoded separately at display resolution below.
    final provider = AttachmentImage(
      attachmentId: widget.attachment.id,
      url: widget.url,
    );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _detach();
    _listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (!mounted || h <= 0 || w <= 0) return;
        final aspect = w / h;
        if (_aspect != aspect) setState(() => _aspect = aspect);
      },
      onError: (_, _) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _stream = stream;
    stream.addListener(_listener!);
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.errorBuilder(context, 80);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 300.0;
        // Height the image would take at its natural aspect ratio, capped.
        final natural = _aspect == null ? _estimatedHeight : width / _aspect!;
        final height = natural.clamp(0.0, widget.maxHeight);

        final dpr = MediaQuery.devicePixelRatioOf(context);
        final decodeWidth = ((width * dpr) / 160).ceil() * 160;
        return SizedBox(
          width: double.infinity,
          height: height,
          child: Image(
            image: ResizeImage.resizeIfNeeded(
              decodeWidth.clamp(160, 1280).toInt(),
              null,
              AttachmentImage(
                attachmentId: widget.attachment.id,
                url: widget.url,
              ),
            ),
            // Uncapped the box already matches the image, so cover is a no-op;
            // once capped it crops the overflow from the bottom.
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (context, error, stack) =>
                widget.errorBuilder(context, 80),
          ),
        );
      },
    );
  }
}
