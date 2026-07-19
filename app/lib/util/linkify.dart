import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'highlight.dart';

/// A URL found inside a run of text. [start]/[end] index into the source
/// string; [url] is the launchable form (a bare `www.` host gets `https://`).
class UrlMatch {
  final int start;
  final int end; // exclusive
  final String url;
  const UrlMatch({required this.start, required this.end, required this.url});
}

// http(s):// or bare www. followed by non-space, non-angle-bracket chars.
final RegExp _urlPattern = RegExp(
  r'((https?://)|(www\.))[^\s<>]+',
  caseSensitive: false,
);

// Trailing characters that are almost never part of a URL (sentence
// punctuation, quotes). Closing brackets are handled separately so balanced
// pairs inside the URL survive.
const String _trailingTrim = '.,;:!?\'"<>«»';

/// Every URL in [text], with trailing sentence punctuation trimmed off and
/// unbalanced closing brackets dropped (so `(see https://a.com/x)` doesn't eat
/// the paren). Empty when there are none.
List<UrlMatch> findUrls(String text) {
  final out = <UrlMatch>[];
  for (final m in _urlPattern.allMatches(text)) {
    var end = m.end;
    while (end > m.start + 1) {
      final ch = text[end - 1];
      if (_trailingTrim.contains(ch)) {
        end--;
        continue;
      }
      if (ch == ')' || ch == ']' || ch == '}') {
        final slice = text.substring(m.start, end);
        final opens = _count(slice, _openFor(ch));
        final closes = _count(slice, ch);
        if (closes > opens) {
          end--;
          continue;
        }
      }
      break;
    }
    final raw = text.substring(m.start, end);
    final url = raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw;
    out.add(UrlMatch(start: m.start, end: end, url: url));
  }
  return out;
}

String _openFor(String close) => switch (close) {
  ')' => '(',
  ']' => '[',
  '}' => '{',
  _ => close,
};

int _count(String s, String ch) => s.split(ch).length - 1;

/// Splits [text] into spans: URL runs get [linkStyle] plus the recognizer from
/// [recognizerFor] (long-press to open); everything else runs through
/// [highlightSpans] so search matches still tint. The caller owns the
/// recognizers' lifecycle — never build them inline here.
List<InlineSpan> buildLinkedSpans({
  required String text,
  required String query,
  required TextStyle? linkStyle,
  required TextStyle? highlight,
  required GestureRecognizer Function(UrlMatch match) recognizerFor,
}) {
  final urls = findUrls(text);
  if (urls.isEmpty) return highlightSpans(text, query, highlight: highlight);

  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final u in urls) {
    if (u.start > cursor) {
      spans.addAll(
        highlightSpans(text.substring(cursor, u.start), query, highlight: highlight),
      );
    }
    spans.add(
      TextSpan(
        text: text.substring(u.start, u.end),
        style: linkStyle,
        recognizer: recognizerFor(u),
      ),
    );
    cursor = u.end;
  }
  if (cursor < text.length) {
    spans.addAll(highlightSpans(text.substring(cursor), query, highlight: highlight));
  }
  return spans;
}

/// Open a detected link in the platform browser. Best-effort — a malformed or
/// unlaunchable URL is silently ignored.
Future<void> launchLinkUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Nothing sensible to do if the platform can't open it.
  }
}
