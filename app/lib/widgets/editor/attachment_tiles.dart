import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/note.dart';
import '../../util/attachment_image.dart';
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SizedBox(
                width: double.infinity,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Decode at (bucketed) display size — see the note card's
                    // image strip for the rationale.
                    final dpr = MediaQuery.devicePixelRatioOf(context);
                    final width = constraints.maxWidth.isFinite
                        ? constraints.maxWidth * dpr
                        : 1360.0;
                    return Image(
                      image: ResizeImage.resizeIfNeeded(
                        ((width / 320).ceil() * 320).clamp(320, 2048).toInt(),
                        null,
                        AttachmentImage(attachmentId: attachment.id, url: url),
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
            if (onRemove != null)
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.white,
                    tooltip: 'Remove image',
                    onPressed: onRemove,
                  ),
                ),
              ),
          ],
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
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
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
