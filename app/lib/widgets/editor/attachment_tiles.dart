import 'package:flutter/material.dart';
import '../../theme.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/dropped_file.dart';
import '../../models/note.dart';
import '../../util/attachment_image.dart';
import '../../util/download.dart';
import '../../util/mime.dart';

/// An inline image attachment in the editor, with a hover remove button.
/// A null [onRemove] (trashed note) hides the button.
class ImageAttachmentTile extends StatelessWidget {
  final Attachment attachment;
  final String url;
  final VoidCallback? onRemove;

  const ImageAttachmentTile({
    super.key,
    required this.attachment,
    required this.url,
    this.onRemove,
  });

  bool get _isSvg =>
      attachment.mime == 'image/svg+xml' ||
      attachment.mime.toLowerCase().contains('svg');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kRadius),
        child: Stack(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SizedBox(
                width: double.infinity,
                child: _isSvg
                    ? SvgPicture.network(
                        url,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        placeholderBuilder: (context) => Container(
                          height: 80,
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // Decode at (bucketed) display size — see the note
                          // card's image strip for the rationale.
                          final dpr = MediaQuery.devicePixelRatioOf(context);
                          final width = constraints.maxWidth.isFinite
                              ? constraints.maxWidth * dpr
                              : 1360.0;
                          return Image(
                            image: ResizeImage.resizeIfNeeded(
                              ((width / 320).ceil() * 320)
                                  .clamp(320, 2048)
                                  .toInt(),
                              null,
                              AttachmentImage(
                                attachmentId: attachment.id,
                                url: url,
                              ),
                            ),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => Container(
                              height: 80,
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.broken_image_outlined),
                            ),
                          );
                        },
                      ),
              ),
            ),
            // A single square-cornered overlay bar (matching the app's [kRadius]
            // chrome) grouping the image actions, rather than floating circles.
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: kBorderRadius,
                clipBehavior: Clip.antiAlias,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _OverlayAction(
                      icon: Icons.download_outlined,
                      tooltip: 'Download image',
                      onPressed: () => downloadUrl(
                        url,
                        attachment.filename.isEmpty
                            ? 'image'
                            : attachment.filename,
                      ),
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
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact icon button for the image overlay bar: white glyph, transparent
/// fill (the bar behind it supplies the scrim) with a subtle hover/press wash.
class _OverlayAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _OverlayAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        hoverColor: Colors.white.withValues(alpha: 0.12),
        splashColor: Colors.white.withValues(alpha: 0.18),
        highlightColor: Colors.white.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

/// A placeholder for a file that is still uploading — shown in the same slot
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
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadius),
          child: Stack(
            alignment: Alignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SizedBox(
                  width: double.infinity,
                  child: Opacity(
                    opacity: 0.5,
                    child: Image.memory(
                      file.bytes,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => Container(
                        height: 80,
                        color: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(kRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 20,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 10),
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
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(
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
        borderRadius: BorderRadius.circular(kRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
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
                const SizedBox(width: 10),
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
