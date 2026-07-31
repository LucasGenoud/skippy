import 'dart:convert';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';

import '../models/link_preview.dart';
import '../state/link_preview_cache.dart';
import '../util/linkify.dart';

/// A compact link-preview strip: a thumbnail on the left, the page title and
/// site on the right. Tapping it opens the URL. While metadata loads (or when
/// the site exposes none) it shows just the host.
///
/// [topDivider] draws a hairline at the top instead of a full border, used
/// when the strip is a full-bleed continuation attached to the bottom of a
/// note card. [borderRadius] rounds its corners (bottom-only when attached,
/// all-round when standalone in the editor).
class LinkPreviewCard extends StatelessWidget {
  final String url;
  final void Function(String url)? onOpen;
  final BorderRadius borderRadius;
  final bool topDivider;

  const LinkPreviewCard({
    super.key,
    required this.url,
    this.onOpen,
    this.borderRadius = const BorderRadius.all(kRadiusCorner),
    this.topDivider = false,
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
          borderRadius: borderRadius,
          topDivider: topDivider,
        );
      },
    );
  }
}

/// Fixed row height of a single [LinkPreviewCard], exposed so callers that
/// reserve layout space for a stack of previews (e.g. the note grid's action
/// row overlay) can compute how much room a given count will take.
const double kLinkPreviewStripHeight = 60;

class _Strip extends StatelessWidget {
  final String url;
  final LinkPreview? preview;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final bool topDivider;

  const _Strip({
    required this.url,
    required this.preview,
    required this.onTap,
    required this.borderRadius,
    required this.topDivider,
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
            border: topDivider
                ? null
                : Border.all(color: scheme.outlineVariant),
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

/// An [ImageProvider] for a favicon. The server inlines small raster favicons
/// as `data:` URIs (so Flutter web can render them, a cross-origin favicon
/// fetched by `Image.network` is CORS-tainted on CanvasKit and fails). Those
/// must be decoded to bytes: mobile's `NetworkImage` can't fetch the `data:`
/// scheme. Anything else is a plain absolute URL. Returns null when unusable.
ImageProvider? _faviconProvider(String favicon) {
  if (!favicon.startsWith('data:')) return NetworkImage(favicon);
  final comma = favicon.indexOf(',');
  if (comma < 0) return null;
  final isBase64 = favicon.substring(5, comma).contains(';base64');
  final payload = favicon.substring(comma + 1);
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
      return SizedBox(
        width: size,
        height: size,
        child: Image.network(
          image!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : ColoredBox(color: tile),
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
        ? _faviconProvider(favicon)
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
              errorBuilder: (context, _, _) => globe,
            ),
    );
  }
}

/// Preview strips for every unique URL in [text] (capped at [max]). Renders
/// nothing when there are no links. Used standalone in the editor, so each
/// strip is a fully-rounded, bordered card.
class LinkPreviewList extends StatelessWidget {
  final String text;
  final int max;
  final void Function(String url)? onOpen;

  const LinkPreviewList({
    super.key,
    required this.text,
    this.max = 3,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final urls = <String>[];
    for (final u in findUrls(text)) {
      if (!urls.contains(u.url)) urls.add(u.url);
    }
    if (urls.isEmpty) return const SizedBox.shrink();
    final shown = urls.take(max).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          LinkPreviewCard(url: shown[i], onOpen: onOpen),
        ],
      ],
    );
  }
}
