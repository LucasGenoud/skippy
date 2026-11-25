import 'package:flutter/material.dart';
import '../../theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/dropped_file.dart';
import '../../models/note.dart';
import '../../util/attachment_image.dart';
import '../../util/download.dart';
import '../../util/image_clipboard.dart';
import '../../util/mime.dart';
import '../../util/motion.dart';
import '../../util/note_image.dart';
import '../../util/snack.dart';
import '../image_mosaic.dart';

part 'image_viewer.dart';

/// The tiles under a note in the editor: every image in one [ImageMosaic],
/// then other files, each group followed by placeholders for the ones still
/// [uploading] so a tile appears where its attachment will land. Audio is
/// played by the audio-note body, so it is not listed. A null [onRemove]
/// makes the tiles read-only.
List<Widget> attachmentTiles({
  required List<Attachment> attachments,
  required List<DroppedFile> uploading,
  required String Function(Attachment) urlOf,
  required void Function(Attachment)? onRemove,
}) {
  VoidCallback? remove(Attachment attachment) =>
      onRemove == null ? null : () => onRemove(attachment);
  bool isImage(DroppedFile file) => file.mime.startsWith('image/');
  final images = attachments.where((a) => a.isImage).toList();
  final pendingImages = uploading.where(isImage).toList();
  final tileCount = images.length + pendingImages.length;
  final decodeWidth = tileCount == 1 ? _singleDecodeWidth : _tileDecodeWidth;
  return [
    if (tileCount > 0)
      Padding(
        key: const ValueKey('image-mosaic'),
        padding: const EdgeInsets.only(bottom: 12),
        child: ImageMosaic(
          style: MosaicStyle.editor,
          leadImage: images.isNotEmpty
              ? NoteImage.sizeProbe(images.first, urlOf(images.first))
              : MemoryImage(pendingImages.first.bytes),
          tiles: [
            for (var i = 0; i < images.length; i++)
              ImageAttachmentTile(
                key: ValueKey(images[i].id),
                attachment: images[i],
                url: urlOf(images[i]),
                decodeWidth: decodeWidth,
                onRemove: remove(images[i]),
                onOpen: (context) => _showImageViewer(
                  context,
                  images: images,
                  urlOf: urlOf,
                  initial: i,
                ),
              ),
            for (final file in pendingImages)
              UploadingAttachmentTile(key: ObjectKey(file), file: file),
          ],
        ),
      ),
    for (final attachment in attachments.where((a) => !a.isImage && !a.isAudio))
      FileAttachmentTile(
        key: ValueKey(attachment.id),
        attachment: attachment,
        url: urlOf(attachment),
        onRemove: remove(attachment),
      ),
    for (final file in uploading.where((file) => !isImage(file)))
      UploadingAttachmentTile(key: ObjectKey(file), file: file),
  ];
}

// Logical widths editor pictures decode at: an editor wide alone, a column
// of the grid otherwise.
const double _singleDecodeWidth = 680;
const double _tileDecodeWidth = 320;

/// Copies the picture, and says so: nothing else on screen changes.
Future<void> _copyImage(String url) async {
  final copied = await copyImageUrl(url);
  showAppSnack(
    copied ? 'Image copied' : "Couldn't copy the image",
    icon: copied ? Icons.content_copy_outlined : Icons.error_outline,
    kind: copied ? SnackKind.normal : SnackKind.danger,
  );
}

void _downloadImage(Attachment attachment, String url) => downloadUrl(
  url,
  attachment.filename.isEmpty ? 'image' : attachment.filename,
);

/// An SVG is a drawing, not pixels the clipboard can take.
bool _canCopy(Attachment attachment) =>
    canCopyImages && !isSvgAttachment(attachment);

/// An image attachment in the editor, filling the tile its mosaic gives it,
/// with an overlay of its actions. Tapping it calls [onOpen], or shows this
/// picture alone full size when there is none. A null [onRemove] (trashed
/// note) hides the remove button.
class ImageAttachmentTile extends StatelessWidget {
  final Attachment attachment;
  final String url;
  final VoidCallback? onRemove;
  final void Function(BuildContext context)? onOpen;
  final double decodeWidth;

  const ImageAttachmentTile({
    super.key,
    required this.attachment,
    required this.url,
    this.onRemove,
    this.onOpen,
    this.decodeWidth = _singleDecodeWidth,
  });

  void _open(BuildContext context) {
    final open = onOpen;
    if (open != null) {
      open(context);
      return;
    }

    _showImageViewer(context, images: [attachment], urlOf: (_) => url);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: kBorderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            button: true,
            label:
                'View ${attachment.filename.isEmpty ? 'image' : attachment.filename}',
            child: GestureDetector(
              key: Key('open-image-${attachment.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _open(context),
              child: NoteImage(
                attachment: attachment,
                url: url,
                decodeWidth: decodeWidth,
              ),
            ),
          ),
          // One square-cornered bar grouping the image actions, rather than
          // floating circles.
          Positioned(
            top: 8,
            right: 8,
            child: _OverlayBar(
              children: [
                if (_canCopy(attachment))
                  _OverlayAction(
                    icon: Icons.content_copy_outlined,
                    tooltip: 'Copy image',
                    onPressed: () => _copyImage(url),
                  ),
                _OverlayAction(
                  icon: Icons.download_outlined,
                  tooltip: 'Download image',
                  onPressed: () => _downloadImage(attachment, url),
                ),
                if (onRemove != null)
                  _OverlayAction(
                    icon: Icons.close,
                    tooltip: 'Remove image',
                    onPressed: onRemove!,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The dark bar image actions sit in, over a picture. Its actions keep an
/// inset from its edge, their corners concentric with the bar's.
class _OverlayBar extends StatelessWidget {
  final List<Widget> children;

  const _OverlayBar({required this.children});

  static const double _inset = 2;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.55),
    borderRadius: kBorderRadius,
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(_inset),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}

/// A compact icon button for the image overlay bar: white glyph, transparent
/// fill (the bar behind it supplies the scrim) with a subtle hover/press wash.
class _OverlayAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  const _OverlayAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: const BorderRadius.all(
          Radius.circular(kRadius - _OverlayBar._inset),
        ),
        hoverColor: Colors.white.withValues(alpha: 0.12),
        splashColor: Colors.white.withValues(alpha: 0.18),
        highlightColor: Colors.white.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: size, color: Colors.white),
        ),
      ),
    );
  }
}

/// A placeholder for a file that is still uploading, shown in the same slot
/// its real [ImageAttachmentTile]/[FileAttachmentTile] takes once the network
/// call resolves, so the tile appears the instant a file is picked instead of
/// popping into existence only on success. The bytes are already in memory
/// (the file was just picked or dropped), so an image preview renders
/// immediately, just dimmed under a spinner.
class UploadingAttachmentTile extends StatelessWidget {
  final DroppedFile file;
  const UploadingAttachmentTile({super.key, required this.file});

  bool get _isImage => file.mime.startsWith('image/');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_isImage) {
      return ClipRRect(
        borderRadius: kBorderRadius,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0.5,
              child: Image.memory(
                file.bytes,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    ColoredBox(color: NoteImage.placeholderOf(context)),
              ),
            ),
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: kBorderRadius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 20,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: kSpaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name.isEmpty ? 'file' : file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      'Uploading… ${formatBytes(file.bytes.length)}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A non-image, non-audio attachment: a download tile opening [url]
/// externally. A null [onRemove] (trashed note) hides the remove button.
class FileAttachmentTile extends StatelessWidget {
  final Attachment attachment;
  final String url;
  final VoidCallback? onRemove;

  const FileAttachmentTile({
    super.key,
    required this.attachment,
    required this.url,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: kBorderRadius,
        child: InkWell(
          borderRadius: kBorderRadius,
          onTap: () =>
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: kSpaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.filename.isEmpty
                            ? 'file'
                            : attachment.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        formatBytes(attachment.size),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.download_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                if (onRemove != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Remove file',
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
