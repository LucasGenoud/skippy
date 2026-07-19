import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// An image provider for note attachments whose cache identity is the
/// attachment id, not the URL.
///
/// File URLs carry a signed, time-limited capability that rotates every
/// clock hour; keying the image cache on the URL would flush every rendered
/// image at each rollover (a grid-wide burst of refetches and decodes).
/// Attachment bytes are immutable, so the id is the correct identity — the
/// current signed URL is only consulted when the bytes actually need
/// fetching.
class AttachmentImage extends ImageProvider<AttachmentImage> {
  final String attachmentId;
  final String url;

  const AttachmentImage({required this.attachmentId, required this.url});

  @override
  Future<AttachmentImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AttachmentImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AttachmentImage key,
    ImageDecoderCallback decode,
  ) {
    // `this` (not `key`) carries the freshest URL: the cache may hand back
    // an old instance as the key, but loading always runs on the provider
    // from the current build.
    final network = NetworkImage(url);
    return network.loadImage(network, decode);
  }

  @override
  bool operator ==(Object other) =>
      other is AttachmentImage && other.attachmentId == attachmentId;

  @override
  int get hashCode => attachmentId.hashCode;
}
