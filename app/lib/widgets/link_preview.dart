import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  final void Function(String url)? onStopSummarize;
  final bool summarizing;
  final BorderRadius borderRadius;
  final bool topDivider;
  final bool outlined;

  const LinkPreviewCard({
    super.key,
    required this.url,
    this.onOpen,
    this.onSummarize,
    this.onStopSummarize,
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
      initialData: cache.resolved(url),
      builder: (context, snapshot) {
        void open() => (onOpen ?? launchLinkUrl)(url);
        return _Strip(
          url: url,
          preview: snapshot.data,
          onTap: open,
          onSummarize: onSummarize == null ? null : () => onSummarize!(url),
          onStopSummarize: onStopSummarize == null
              ? null
              : () => onStopSummarize!(url),
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

/// How long typing must pause before an open note's previews follow it.
const Duration kLinkPreviewSettle = Duration(milliseconds: 500);

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
  final VoidCallback? onStopSummarize;
  final bool summarizing;
  final BorderRadius borderRadius;
  final bool topDivider;
  final bool outlined;

  const _Strip({
    required this.url,
    required this.preview,
    required this.onTap,
    required this.onSummarize,
    required this.onStopSummarize,
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
                      const SizedBox(height: kSpaceLineGap),
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
              tooltip: summarizing ? 'Stop summarizing' : 'Summarize page',
              onPressed: summarizing ? onStopSummarize : onSummarize,
              // While it runs, the spinner rings a stop square: the same
              // button that started the summary is the one that ends it.
              icon: summarizing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox.expand(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          Icon(Icons.stop_rounded, size: 12),
                        ],
                      ),
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
    return bytes.isEmpty ? null : _DataUriImage(imageUrl, bytes);
  } catch (_) {
    return null;
  }
}

/// A [MemoryImage] equal to any other decoded from the same URI. A plain one
/// is equal only to itself, so each rebuild made a new image-cache key, and
/// the thumbnail reloaded and faded in again on every keystroke.
class _DataUriImage extends MemoryImage {
  final String uri;

  const _DataUriImage(this.uri, super.bytes);

  @override
  bool operator ==(Object other) =>
      other is _DataUriImage && other.uri == uri && other.scale == scale;

  @override
  int get hashCode => Object.hash(uri, scale);
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
///
/// The links shown follow [text] once it has been still for
/// [kLinkPreviewSettle], so a link being typed is not unfurled, and its strip
/// replaced, once per keystroke.
class LinkPreviewList extends StatefulWidget {
  final String text;
  final void Function(String url)? onOpen;
  final Future<void> Function(String url)? onSummarize;
  final void Function(String url)? onStopSummarize;
  final Set<String> summarizingUrls;

  const LinkPreviewList({
    super.key,
    required this.text,
    this.onOpen,
    this.onSummarize,
    this.onStopSummarize,
    this.summarizingUrls = const {},
  });

  @override
  State<LinkPreviewList> createState() => _LinkPreviewListState();
}

class _LinkPreviewListState extends State<LinkPreviewList> {
  late List<String> _urls = linkPreviewUrls(widget.text);
  Timer? _settle;

  @override
  void didUpdateWidget(LinkPreviewList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) {
      return;
    }

    _settle?.cancel();
    _settle = Timer(kLinkPreviewSettle, () {
      final urls = linkPreviewUrls(widget.text);
      if (!listEquals(urls, _urls)) {
        setState(() => _urls = urls);
      }
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls;
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
                // Keyed by link so a link added above another keeps each
                // card on its own preview.
                key: ValueKey(urls[i]),
                url: urls[i],
                onOpen: widget.onOpen,
                onSummarize: widget.onSummarize,
                onStopSummarize: widget.onStopSummarize,
                summarizing: widget.summarizingUrls.contains(urls[i]),
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

/// Width over height of the image a bookmark leads with, the Open Graph
/// standard, so pages' share images fit without cropping.
const double _bookmarkImageAspect = 1.91;
const double _bookmarkFaviconSize = 16;
const int _bookmarkTitleLines = 3;
const int _bookmarkBodyLines = 4;

/// A note that is just a link, shown as what the link is: the page's image
/// full width, its title and description, and where it lives. Under the link
/// the note's own text, when there is any, takes the description's place.
///
/// Metadata arriving grows the card smoothly rather than popping it taller,
/// and the image fades in over its slot.
class BookmarkCard extends StatelessWidget {
  final String url;

  /// The note's own title, which leads when set: it is the name the user
  /// gave the bookmark.
  final String noteTitle;

  /// Text written under the link.
  final String body;

  final BorderRadius imageRadius;

  const BookmarkCard({
    super.key,
    required this.url,
    this.noteTitle = '',
    this.body = '',
    this.imageRadius = const BorderRadius.vertical(top: kCardCorner),
  });

  @override
  Widget build(BuildContext context) {
    final cache = context.read<LinkPreviewCache>();
    return FutureBuilder<LinkPreview?>(
      future: cache.preview(url),
      initialData: cache.resolved(url),
      builder: (context, snapshot) => AnimatedSize(
        duration: Motion.reduced(context) ? Duration.zero : Motion.base,
        curve: Motion.emphasized,
        alignment: Alignment.topCenter,
        child: _bookmark(context, snapshot.data),
      ),
    );
  }

  Widget _bookmark(BuildContext context, LinkPreview? preview) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final host = preview?.host ?? _Strip._hostOf(url);
    final image = preview?.image;
    final imageProvider = image == null ? null : _previewImageProvider(image);
    final pageTitle = preview?.title;
    final description = body.isNotEmpty ? body : preview?.description;
    final title = noteTitle.isNotEmpty ? noteTitle : (pageTitle ?? host);
    final subtitle = noteTitle.isNotEmpty ? pageTitle : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (imageProvider != null)
          ClipRRect(
            borderRadius: imageRadius,
            child: AspectRatio(
              aspectRatio: _bookmarkImageAspect,
              child: ColoredBox(
                color: scheme.onSurface.withValues(alpha: 0.06),
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: Motion.fadeInFrame,
                  errorBuilder: (context, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The host gives way to the page title once it is known.
              StateCrossFade(
                state: title,
                child: Text(
                  title,
                  maxLines: _bookmarkTitleLines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: kSpaceXs),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (description != null && description.isNotEmpty) ...[
                const SizedBox(height: kSpaceXs),
                Text(
                  description,
                  maxLines: _bookmarkBodyLines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: kSpaceXs),
              Row(
                children: [
                  _BookmarkFavicon(favicon: preview?.favicon),
                  const SizedBox(width: kSpaceInline),
                  Expanded(
                    child: Text(
                      host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open link',
                    visualDensity: VisualDensity.compact,
                    iconSize: kCompactIconSize,
                    color: scheme.onSurfaceVariant,
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => launchLinkUrl(url),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BookmarkFavicon extends StatelessWidget {
  final String? favicon;

  const _BookmarkFavicon({required this.favicon});

  @override
  Widget build(BuildContext context) {
    final globe = Icon(
      Icons.public,
      size: _bookmarkFaviconSize,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final icon = favicon;
    final provider = icon == null || icon.isEmpty
        ? null
        : _previewImageProvider(icon);
    if (provider == null) {
      return globe;
    }
    return Image(
      image: provider,
      width: _bookmarkFaviconSize,
      height: _bookmarkFaviconSize,
      fit: BoxFit.contain,
      frameBuilder: Motion.fadeInFrame,
      errorBuilder: (context, _, _) => globe,
    );
  }
}
