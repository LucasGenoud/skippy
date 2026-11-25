import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/note.dart';
import 'attachment_image.dart';
import 'motion.dart';

/// A note image attachment filling the box it is given, cropped to cover it.
/// The box comes from the layout around it ([ImageMosaic]), which already
/// knows the picture's shape, so this only draws.
///
/// Raster pictures decode at [decodeWidth] logical pixels (bucketed, so tiles
/// of nearby sizes share a cache entry) and fade in over a quiet placeholder.
/// SVG bytes are not a raster the image decoder can read, so those draw
/// through [SvgPicture].
class NoteImage extends StatelessWidget {
  final Attachment attachment;
  final String url;
  final double decodeWidth;
  final Alignment alignment;

  const NoteImage({
    super.key,
    required this.attachment,
    required this.url,
    required this.decodeWidth,
    this.alignment = Alignment.center,
  });

  static const int _decodeBucket = 160;
  static const int _minDecode = 160;
  static const int _maxDecode = 1280;

  /// What a tile shows before its picture lands, and if it never does.
  static Color placeholderOf(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);

  /// The provider a tile decodes from, unresized: [ImageMosaic] reads its
  /// size to shape a lone picture.
  static ImageProvider? sizeProbe(Attachment attachment, String url) =>
      isSvgAttachment(attachment)
      ? null
      : AttachmentImage(attachmentId: attachment.id, url: url);

  Widget _broken(BuildContext context) => Center(
    child: Icon(
      Icons.broken_image_outlined,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final picture = isSvgAttachment(attachment)
        ? SvgPicture.network(
            url,
            fit: BoxFit.cover,
            alignment: alignment,
            placeholderBuilder: (_) => const SizedBox.shrink(),
          )
        : Image(
            image: ResizeImage.resizeIfNeeded(
              _cacheWidth(context),
              null,
              _raster,
            ),
            fit: BoxFit.cover,
            alignment: alignment,
            frameBuilder: Motion.fadeInFrame,
            errorBuilder: (context, error, stack) => _broken(context),
          );
    return ColoredBox(
      color: placeholderOf(context),
      child: SizedBox.expand(child: picture),
    );
  }

  ImageProvider get _raster =>
      AttachmentImage(attachmentId: attachment.id, url: url);

  int _cacheWidth(BuildContext context) {
    final pixels = decodeWidth * MediaQuery.devicePixelRatioOf(context);
    final bucketed = (pixels / _decodeBucket).ceil() * _decodeBucket;
    return bucketed.clamp(_minDecode, _maxDecode);
  }
}

/// SVG is a drawing, not pixels: it renders through a different path and
/// cannot go on the clipboard as an image.
bool isSvgAttachment(Attachment attachment) =>
    attachment.mime.toLowerCase().contains('svg');
