import 'dart:convert';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';

import '../models/link_preview.dart';
import '../models/note.dart';
import '../state/link_preview_cache.dart';
import '../util/linkify.dart';
import '../util/motion.dart';
import 'state_cross_fade.dart';

/// A compact link-preview strip: a thumbnail on the left, the page title and
/// site on the right. Tapping it opens the URL. While metadata loads (or when
/// the site exposes none) it shows just the host.
///
/// [topDivider] draws the hairline that attaches a row to the note above it
/// or separates rows in a preview group.
class LinkPreviewCard extends StatelessWidget {
  final String url;
  final void Function(String url)? onOpen;
  final Future<void> Function(String url)? onSummarize;
  final bool summarizing;
  final BorderRadius borderRadius;
  final bool topDivider;
  final bool outlined;

  const LinkPreviewCard({
    super.key,
    required this.url,
    this.onOpen,
    this.onSummarize,
    this.summarizing = false,
    this.borderRadius = const BorderRadius.all(kRadiusCorner),
    this.topDivider = false,
    this.outlined = true,
  });

  @override
  Widget build(BuildContext context) {
    final cache = context.read<LinkPreviewCache>();
    return FutureBuilder<LinkPreview?>(
      future: cache.preview(url),
      builder: (context, snapshot) {
        void open() => (onOpen ?? launchLinkUrl)(url);
        return _Strip(
          url: url,
          preview: snapshot.data,
          onTap: open,
          onSummarize: onSummarize == null ? null : () => onSummarize!(url),
          summarizing: summarizing,
          borderRadius: borderRadius,
          topDivider: topDivider,
          outlined: outlined,
        );
      },
    );
  }
}

/// Fixed row height of a single [LinkPreviewCard], exposed so callers that
/// reserve layout space for a stack of previews (e.g. the note grid's action
/// row overlay) can compute how much room a given count will take.
const double kLinkPreviewStripHeight = 60;
const int kMaxLinkPreviewCards = 5;

List<String> linkPreviewUrls(String text) => findUrls(
  text,
).map((match) => match.url).toSet().take(kMaxLinkPreviewCards).toList();

/// Include checklist rows as well as the title and body in both card and editor previews.
String noteLinkText(Note note) => [
  note.title,
  note.content,
  for (final item in note.items) item.text,
].join('\n');

class _Strip extends StatelessWidget {
  final String url;
  final LinkPreview? preview;
  final VoidCallback onTap;
  final Future<void> Function()? onSummarize;
  final bool summarizing;
  final BorderRadius borderRadius;
  final bool topDivider;
  final bool outlined;

  const _Strip({
    required this.url,
    required this.preview,
    required this.onTap,
    required this.onSummarize,
    required this.summarizing,
    required this.borderRadius,
    required this.topDivider,
    required this.outlined,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final host = preview?.host ?? _hostOf(url);
    final rich = preview?.hasRichContent ?? false;
    final title = rich ? (preview!.title ?? host) : host;
    final subtitle = rich ? (preview!.siteName ?? host) : null;

    final row = SizedBox(
      height: kLinkPreviewStripHeight,
      child: Row(
        children: [
          _Thumb(
            image: preview?.image,
            favicon: preview?.favicon,
            size: kLinkPreviewStripHeight,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              // The bare host cross-fades to the page's title once the
              // preview arrives, rather than the text swapping in one frame.
              child: StateCrossFade(
                state: rich,
                alignment: AlignmentDirectional.centerStart,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (onSummarize != null)
            IconButton(
              tooltip: 'Summarize page',
              onPressed: summarizing ? null : onSummarize,
              icon: summarizing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined, size: 18),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: Icon(
                Icons.open_in_new,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );

    // A translucent overlay so the strip reads as an attached panel on top of
    // whatever the note's colour is (works on white and coloured notes alike).
    return Material(
      color: scheme.onSurface.withValues(alpha: 0.045),
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: outlined && !topDivider
                ? Border.all(color: scheme.outlineVariant)
                : null,
          ),
          child: topDivider
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: scheme.onSurface.withValues(alpha: 0.08),
                    ),
                    row,
                  ],
                )
              : row,
        ),
      ),
    );
  }

  static String _hostOf(String url) {
    final h = Uri.tryParse(url)?.host ?? url;
    return h.startsWith('www.') ? h.substring(4) : h;
  }
}

/// An [ImageProvider] for a preview image or favicon. The server inlines small
/// raster images as `data:` URIs because a cross-origin [NetworkImage] can be
/// CORS-tainted on Flutter web. Mobile's [NetworkImage] cannot load that
/// scheme, so data URIs are decoded directly.
ImageProvider? _previewImageProvider(String imageUrl) {
  if (!imageUrl.startsWith('data:')) return NetworkImage(imageUrl);
  final comma = imageUrl.indexOf(',');
  if (comma < 0) return null;
  final isBase64 = imageUrl.substring(5, comma).contains(';base64');
  final payload = imageUrl.substring(comma + 1);
  try {
    final bytes = isBase64
        ? base64Decode(payload)
        : utf8.encode(Uri.decodeComponent(payload));
    return bytes.isEmpty ? null : MemoryImage(bytes);
  } catch (_) {
    return null;
  }
}

/// The strip's leading square: the Open Graph image if there is one, otherwise
/// the favicon on a tinted tile, otherwise a globe glyph. Favicons are often
/// `.ico` (which Flutter can't decode) so every image has a graceful fallback.
class _Thumb extends StatelessWidget {
  final String? image;
  final String? favicon;
  final double size;
  const _Thumb({
    required this.image,
    required this.favicon,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = scheme.onSurface.withValues(alpha: 0.06);
    if (image != null && image!.isNotEmpty) {
      final provider = _previewImageProvider(image!);
      if (provider == null) return _faviconTile(context, tile, favicon, size);
      // The tile shows through until the thumbnail has faded in over it.
      return Container(
        width: size,
        height: size,
        color: tile,
        child: Image(
          image: provider,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: Motion.fadeInFrame,
          errorBuilder: (context, _, _) =>
              _faviconTile(context, tile, favicon, size),
        ),
      );
    }
    return _faviconTile(context, tile, favicon, size);
  }

  static Widget _faviconTile(
    BuildContext context,
    Color tile,
    String? favicon,
    double size,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final globe = Icon(Icons.public, size: 22, color: scheme.onSurfaceVariant);
    final provider = (favicon != null && favicon.isNotEmpty)
        ? _previewImageProvider(favicon)
        : null;
    return Container(
      width: size,
      height: size,
      color: tile,
      alignment: Alignment.center,
      child: provider == null
          ? globe
          : Image(
              image: provider,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              frameBuilder: Motion.fadeInFrame,
              errorBuilder: (context, _, _) => globe,
            ),
    );
  }
}

/// Up to five unique previews in one rounded rectangle, with row dividers.
class LinkPreviewList extends StatelessWidget {
  final String text;
  final void Function(String url)? onOpen;
  final Future<void> Function(String url)? onSummarize;
  final Set<String> summarizingUrls;

  const LinkPreviewList({
    super.key,
    required this.text,
    this.onOpen,
    this.onSummarize,
    this.summarizingUrls = const {},
  });

  @override
  Widget build(BuildContext context) {
    final urls = linkPreviewUrls(text);
    if (urls.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: const BorderRadius.all(kRadiusCorner),
      ),
      child: ClipRRect(
        key: const Key('link-preview-group'),
        borderRadius: const BorderRadius.all(kRadiusCorner),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < urls.length; i++)
              LinkPreviewCard(
                url: urls[i],
                onOpen: onOpen,
                onSummarize: onSummarize,
                summarizing: summarizingUrls.contains(urls[i]),
                topDivider: i > 0,
                outlined: false,
                borderRadius: BorderRadius.zero,
              ),
          ],
        ),
      ),
    );
  }
}
