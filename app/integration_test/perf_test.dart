import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/checklist/pop_checkbox.dart';
import 'package:skippy/widgets/note_card.dart';

import '../test/fake_api.dart';
import '../test/notes_store_test.dart' show serverNote;
import '../test/widget_test.dart' show homeApp;

const _md =
    '# Heading\n\nSome **bold** and _italic_ text with a '
    '[link](https://example.com).\n\n- one\n- two\n- three\n\n> quote';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('interaction frame cost', (t) async {
    final api = FakeApi();
    final store = NotesStore(api: api, currentUserId: 'u-me');
    for (var i = 0; i < 200; i++) {
      final kind = [
        NoteKind.text,
        NoteKind.markdown,
        NoteKind.checklist,
        NoteKind.text,
      ][i % 4];
      api.notes['n$i'] = serverNote(
        'n$i',
        title: 'Note $i',
        kind: kind,
        position: (200 - i).toDouble(),
        workspaceId: 'w-default',
        content: kind == NoteKind.markdown
            ? _md
            : List.filled(
                1 + i % 5,
                'Body text https://example.com/page and words',
              ).join(' '),
        items: kind == NoteKind.checklist
            ? [
                for (var j = 0; j < 6; j++)
                  ChecklistItem(
                    id: 'i$i-$j',
                    text: 'item $j',
                    done: j > 3,
                    depth: j == 2 ? 1 : 0,
                  ),
              ]
            : const [],
      );
    }
    await store.load();
    await t.pumpWidget(
      Provider(
        create: (_) => LinkPreviewCache(api: api),
        child: homeApp(store),
      ),
    );
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 1));

    Finder tileOf(NoteKind kind) => find
        .byWidgetPredicate((w) => w is NoteTile && w.note.kind == kind)
        .first;
    final grid = find
        .ancestor(
          of: find.byType(NoteTile).first,
          matching: find.byType(Scrollable),
        )
        .first;
    Future<void> back() async {
      await t.tap(find.byTooltip('Back').first);
      await t.pumpAndSettle();
    }

    Future<void> watch(String key, Future<void> Function() action) =>
        binding.watchPerformance(action, reportKey: key);

    await watch('scroll_fling', () async {
      for (var i = 0; i < 4; i++) {
        await t.fling(grid, const Offset(0, -900), 3000);
        await t.pumpAndSettle();
      }
      for (var i = 0; i < 4; i++) {
        await t.fling(grid, const Offset(0, 900), 3000);
        await t.pumpAndSettle();
      }
    });

    await watch('open_text_note', () async {
      await t.tap(tileOf(NoteKind.text));
      await t.pumpAndSettle();
    });
    await watch('type_text_note', () async {
      final field = find.byType(EditableText).last;
      final ctrl = t.widget<EditableText>(field).controller;
      for (final ch in ' quick brown fox'.split('')) {
        await t.enterText(field, ctrl.text + ch);
        await t.pump(const Duration(milliseconds: 60));
      }
      await t.pumpAndSettle();
    });
    await watch('close_text_note', back);

    await watch('open_checklist_note', () async {
      await t.tap(tileOf(NoteKind.checklist));
      await t.pumpAndSettle();
    });
    await watch('toggle_checklist_item', () async {
      for (var i = 0; i < 2; i++) {
        await t.tap(find.byType(PopCheckbox).first);
        await t.pumpAndSettle();
      }
    });
    await watch('close_checklist_note', back);

    await watch('open_markdown_note', () async {
      await t.tap(tileOf(NoteKind.markdown));
      await t.pumpAndSettle();
    });
    await watch('close_markdown_note', back);

    await watch('open_drawer', () async {
      await t.tap(find.byIcon(Icons.menu).first);
      await t.pumpAndSettle();
    });
    await watch('switch_to_archive', () async {
      await t.tap(find.text('Archive').last);
      await t.pumpAndSettle();
    });
    await watch('switch_to_notes', () async {
      await t.tap(find.byIcon(Icons.menu).first);
      await t.pumpAndSettle();
      await t.tap(find.text('General').last);
      await t.pumpAndSettle();
    });

    await watch('swipe_to_archive', () async {
      await t.timedDrag(
        find.byType(NoteTile).at(1),
        const Offset(300, 0),
        const Duration(milliseconds: 300),
      );
      await t.pumpAndSettle();
    });

    await watch('search_typing', () async {
      await t.tap(find.text('Search your notes'));
      await t.pumpAndSettle();
      final field = find.byType(EditableText).first;
      var q = '';
      for (final ch in 'note 1'.split('')) {
        q += ch;
        await t.enterText(field, q);
        await t.pump(const Duration(milliseconds: 80));
      }
      await t.pumpAndSettle();
    });
  });
}
