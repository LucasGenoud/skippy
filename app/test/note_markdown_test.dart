import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/note_markdown.dart';

Widget _markdown(String data, CodeBlockMode mode) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => MarkdownBody(
        data: data,
        styleSheet: noteMarkdownStyle(Theme.of(context)),
        builders: noteMarkdownBuilders(mode),
      ),
    ),
  ),
);

const _fence = '```dart\nfinal x = 1;\n```';

void main() {
  testWidgets('a fenced block shows its language and a copy button', (
    tester,
  ) async {
    await tester.pumpWidget(_markdown(_fence, CodeBlockMode.interactive));

    expect(find.text('DART'), findsOneWidget);
    expect(find.byTooltip('Copy code'), findsOneWidget);
    expect(
      find.textContaining('final x = 1;', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a card preview draws the code without a copy button', (
    tester,
  ) async {
    await tester.pumpWidget(_markdown(_fence, CodeBlockMode.preview));

    expect(find.text('DART'), findsOneWidget);
    expect(find.byTooltip('Copy code'), findsNothing);
  });
}
