import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/widgets/editor/note_actions_button.dart';
import 'package:skippy/widgets/move_note_sheet.dart';
import 'finders.dart';

/// The app-bar menu is the "do things *to* this note" half of the editor. It
/// must stay one flat list: an earlier design nested the rarer half behind
/// "More note options", which put common-but-infrequent actions such as
/// Move to column three taps deep.
void main() {
  Widget menu({
    bool isOwner = true,
    NoteKind kind = NoteKind.text,
    void Function(NoteKind)? onConvert,
    ValueChanged<NoteRewriteTask>? onRewrite,
    ValueChanged<int>? onGridSpan,
    bool fromBoard = false,
    ValueChanged<NoteMoveTarget>? onMove,
    VoidCallback? onCopy,
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
            onCopy: onCopy,
            moveTargets: [
              if (fromBoard) NoteMoveTarget.stage,
              NoteMoveTarget.workspace,
            ],
            onMove: onMove ?? (_) {},
            onHistory: () {},
            onConvert: onConvert,
            onRewrite: onRewrite,
            onGridSpan: onGridSpan,
            rewriting: rewriting,
          ),
        ],
      ),
    ),
  );

  testWidgets('every note action is one tap inside a single flat sheet', (
    tester,
  ) async {
    await tester.pumpWidget(menu(fromBoard: true));
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();

    for (final label in ['Share', 'Move to…', 'Version history', 'Duplicate']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Delete'), findsOneWidget);
    // No second level to navigate.
    expect(find.text('More note options'), findsNothing);
    // Only what the note offers: no copy or archive callback, no tile.
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Archive'), findsNothing);
  });

  testWidgets('the frequent actions share one row above the rest', (
    tester,
  ) async {
    var copied = false;
    await tester.pumpWidget(menu(onCopy: () => copied = true));
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();

    final copy = tester.getCenter(find.text('Copy'));
    expect(tester.getCenter(find.text('Share')).dy, copy.dy);
    expect(tester.getCenter(find.text('Delete')).dy, copy.dy);
    expect(
      tester.getCenter(find.text('Version history')).dy,
      greaterThan(copy.dy),
    );

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, isTrue);
  });

  testWidgets('the kinds of move are one row that opens on the first', (
    tester,
  ) async {
    NoteMoveTarget? opened;
    await tester.pumpWidget(
      menu(fromBoard: true, onMove: (target) => opened = target),
    );
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();

    expect(find.text('Move to column'), findsNothing);
    expect(find.text('Move to workspace'), findsNothing);
    await tester.tap(find.text('Move to…'));
    await tester.pumpAndSettle();
    expect(opened, NoteMoveTarget.stage);
  });

  testWidgets('rewrite and convert collapse into chip rows', (tester) async {
    NoteRewriteTask? rewritten;
    NoteKind? converted;
    await tester.pumpWidget(
      menu(
        kind: NoteKind.text,
        onRewrite: (mode) => rewritten = mode,
        onConvert: (target) => converted = target,
      ),
    );

    await tester.tap(findAction('Note actions'));
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

    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Fix grammar'));
    await tester.tap(find.text('Fix grammar'));
    await tester.pumpAndSettle();
    expect(rewritten, kDefaultNoteRewriteTasks[1]);
  });

  testWidgets('audio notes are convertible away from but never into', (
    tester,
  ) async {
    await tester.pumpWidget(menu(kind: NoteKind.audio, onConvert: (_) {}));
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();

    expect(find.text('Text'), findsOneWidget);
    expect(find.text('Checklist'), findsOneWidget);
    // Rewriting a transcript is not offered either.
    expect(find.text('Rewrite with AI'), findsNothing);
  });

  testWidgets('card width choices report the selected span', (tester) async {
    int? selected;
    await tester.pumpWidget(menu(onGridSpan: (span) => selected = span));
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();

    expect(find.text('Card width'), findsOneWidget);
    await tester.tap(find.text('2 columns'));
    await tester.pumpAndSettle();
    expect(selected, 2);
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
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();
    // With one kind of destination, the row names it.
    expect(find.text('Move to…'), findsNothing);
    expect(find.text('Move to workspace'), findsOneWidget);
  });

  testWidgets('only the owner is offered Delete', (tester) async {
    await tester.pumpWidget(menu(isOwner: false));
    await tester.tap(findAction('Note actions'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Share'), findsOneWidget);
  });
}
