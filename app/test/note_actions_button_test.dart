import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/widgets/editor/note_actions_button.dart';

/// The app-bar menu is the "do things *to* this note" half of the editor. It
/// must stay one flat list: an earlier design nested the rarer half behind
/// "More note options", which put common-but-infrequent actions such as
/// Move to column three taps deep.
void main() {
  Widget menu({
    bool isOwner = true,
    NoteKind kind = NoteKind.text,
    void Function(NoteKind)? onConvert,
    ValueChanged<NoteRewriteMode>? onRewrite,
    VoidCallback? onMoveToStage,
    VoidCallback? onDelete,
    VoidCallback? onShare,
    bool rewriting = false,
  }) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(
        actions: [
          NoteActionsButton(
            isOwner: isOwner,
            kind: kind,
            onShare: onShare ?? () {},
            onDelete: onDelete ?? () {},
            onDuplicate: () {},
            onMoveToWorkspace: () {},
            onMoveToStage: onMoveToStage,
            onHistory: () {},
            onConvert: onConvert,
            onRewrite: onRewrite,
            rewriting: rewriting,
          ),
        ],
      ),
    ),
  );

  testWidgets('every note action is one tap inside a single flat sheet', (
    tester,
  ) async {
    await tester.pumpWidget(menu(onMoveToStage: () {}));
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();

    for (final label in [
      'Collaborators',
      'Move to column',
      'Move to workspace',
      'Version history',
      'Duplicate',
      'Delete',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // No second level to navigate.
    expect(find.text('More note options'), findsNothing);
    // Promoted to app-bar buttons of their own, so they are not duplicated
    // as rows here.
    expect(find.text('Copy to clipboard'), findsNothing);
    expect(find.text('Archive'), findsNothing);
  });

  testWidgets('rewrite and convert collapse into chip rows', (tester) async {
    NoteRewriteMode? rewritten;
    NoteKind? converted;
    await tester.pumpWidget(
      menu(
        kind: NoteKind.text,
        onRewrite: (mode) => rewritten = mode,
        onConvert: (target) => converted = target,
      ),
    );

    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    expect(find.text('Rewrite with AI'), findsOneWidget);
    expect(find.text('Make concise'), findsOneWidget);
    expect(find.text('Turn into'), findsOneWidget);
    // The note's own kind is not offered as a destination.
    expect(find.text('Text'), findsNothing);
    expect(find.text('Checklist'), findsOneWidget);
    expect(find.text('Markdown'), findsOneWidget);

    await tester.tap(find.text('Checklist'));
    await tester.pumpAndSettle();
    expect(converted, NoteKind.checklist);

    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix grammar'));
    await tester.pumpAndSettle();
    expect(rewritten, NoteRewriteMode.grammar);
  });

  testWidgets('audio notes are convertible away from but never into', (
    tester,
  ) async {
    await tester.pumpWidget(menu(kind: NoteKind.audio, onConvert: (_) {}));
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();

    expect(find.text('Text'), findsOneWidget);
    expect(find.text('Checklist'), findsOneWidget);
    // Rewriting a transcript is not offered either.
    expect(find.text('Rewrite with AI'), findsNothing);
  });

  testWidgets('a rewrite in flight replaces the trigger with a spinner', (
    tester,
  ) async {
    await tester.pumpWidget(menu(onRewrite: (_) {}, rewriting: true));
    expect(
      find.byKey(const ValueKey('editor-rewrite-progress')),
      findsOneWidget,
    );
  });

  testWidgets('Move to column is absent unless the note came from a board', (
    tester,
  ) async {
    await tester.pumpWidget(menu());
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    expect(find.text('Move to column'), findsNothing);
    expect(find.text('Move to workspace'), findsOneWidget);
  });

  testWidgets('only the owner is offered Delete', (tester) async {
    await tester.pumpWidget(menu(isOwner: false));
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Collaborators'), findsOneWidget);
  });
}
