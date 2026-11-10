import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme.dart';
import '../util/app_fonts.dart';
import '../util/code_highlight.dart';
import '../util/snack.dart';

/// How a code block behaves where it is drawn.
enum CodeBlockMode {
  /// The editor, the chat and the public page: scrolls sideways, offers copy,
  /// and its text can be selected.
  interactive,

  /// A card in the grid: clipped at its edge, inert, nothing to press.
  preview,
}

/// Monospace for code: the bundled JetBrains Mono, with each platform's own
/// monospace behind it until the face is registered.
const _codeFamily = 'JetBrainsMono';
const _codeFallback = ['monospace', 'Menlo', 'Consolas', 'Courier New'];

/// Code sits a little smaller than prose, as monospace reads larger.
const _codeScale = 0.9;

/// The style every markdown note shares. [body] overrides the paragraph style.
MarkdownStyleSheet noteMarkdownStyle(ThemeData theme, {TextStyle? body}) {
  // Text drawn before the face lands falls back, then relays out on its own
  // once the engine registers it.
  AppFontLoader.instance.load(AppFont.jetBrainsMono);

  final scheme = theme.colorScheme;
  final p = body ?? theme.textTheme.bodyMedium;
  final size = (p?.fontSize ?? 14) * _codeScale;
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: p,
    code: TextStyle(
      fontFamily: _codeFamily,
      fontFamilyFallback: _codeFallback,
      fontSize: size,
      color: scheme.onSurface,
      backgroundColor: codeFillColor(scheme),
    ),
    // [_CodeBlockBuilder] draws the block's own fill, edge and padding.
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: kSpaceMd),
  );
}

/// The custom element builders a note's markdown uses.
Map<String, MarkdownElementBuilder> noteMarkdownBuilders(CodeBlockMode mode) =>
    {'pre': _CodeBlockBuilder(mode)};

/// Replaces the stock fenced block (plain text on a grey box) with a
/// highlighted one under a language label.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  final CodeBlockMode mode;
  _CodeBlockBuilder(this.mode);

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final language = (code?.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    // A fence always ends in a newline the reader never typed.
    final source = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return _CodeBlock(source: source, language: language, mode: mode);
  }
}

class _CodeBlock extends StatelessWidget {
  final String source;
  final String language;
  final CodeBlockMode mode;

  const _CodeBlock({
    required this.source,
    required this.language,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final interactive = mode == CodeBlockMode.interactive;
    final showHeader = language.isNotEmpty || interactive;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: kSpaceXs),
      decoration: BoxDecoration(
        color: codeFillColor(scheme),
        borderRadius: kBorderRadius,
        border: Border.all(color: hairlineColor(scheme)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showHeader) _header(context, interactive),
          Padding(
            padding: EdgeInsets.fromLTRB(
              kSpaceMd,
              showHeader ? 0 : kSpaceSm + 2,
              kSpaceMd,
              kSpaceSm + 2,
            ),
            child: interactive
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText.rich(_spans(context)),
                  )
                : Text.rich(
                    _spans(context),
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, bool interactive) {
    final theme = Theme.of(context);
    final label = Text(
      language.toUpperCase(),
      style: sectionLabelStyle(theme)?.copyWith(fontSize: 10.5),
    );
    if (!interactive) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(kSpaceMd, kSpaceSm, kSpaceMd, 2),
        child: label,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: kSpaceMd),
      child: Row(
        children: [
          Expanded(child: label),
          IconButton(
            tooltip: 'Copy code',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.onSurfaceVariant,
            icon: const Icon(Icons.content_copy_outlined),
            onPressed: _copy,
          ),
        ],
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: source));
    showAppSnack('Code copied', icon: Icons.content_copy_outlined);
  }

  TextSpan _spans(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = codeSyntaxColors(scheme);
    final base = TextStyle(
      fontFamily: _codeFamily,
      fontFamilyFallback: _codeFallback,
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * _codeScale,
      height: 1.5,
      color: scheme.onSurface,
    );

    TextStyle? styleFor(CodeTokenKind kind) => switch (kind) {
      CodeTokenKind.plain => null,
      CodeTokenKind.keyword => TextStyle(
        color: colors.keyword,
        fontWeight: FontWeight.w600,
      ),
      CodeTokenKind.string => TextStyle(color: colors.string),
      CodeTokenKind.number => TextStyle(color: colors.number),
      CodeTokenKind.comment => TextStyle(
        color: colors.comment,
        fontStyle: FontStyle.italic,
      ),
      CodeTokenKind.type => TextStyle(color: colors.type),
      CodeTokenKind.call => TextStyle(color: colors.call),
    };

    return TextSpan(
      style: base,
      children: [
        for (final token in highlightCode(source, language: language))
          TextSpan(text: token.text, style: styleFor(token.kind)),
      ],
    );
  }
}
