import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/state/link_preview_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/note_card.dart';

import '../test/fake_api.dart';
import '../test/notes_store_test.dart' show serverNote;
import '../test/widget_test.dart' show homeApp;

/// Frame cost of setting a reminder on a phone: the sheet opening, the
/// custom date wheel, and the sheet closing onto a note that now has one.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('reminder frame cost', (t) async {
    final api = FakeApi();
    final store = NotesStore(api: api, currentUserId: 'u-me');
    for (var i = 0; i < 200; i++) {
      api.notes['n$i'] = serverNote(
        'n$i',
        title: 'Note $i',
        position: (200 - i).toDouble(),
        workspaceId: 'w-default',
        content: 'Body text and words ' * (1 + i % 4),
        reminderAt: i % 7 == 0
            ? DateTime.now().add(Duration(days: i)).toUtc()
            : null,
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

    Future<void> watch(String key, Future<void> Function() action) =>
        binding.watchPerformance(action, reportKey: key);

    final preset = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('reminder-preset-'),
    );

    await t.tap(find.byType(NoteTile).at(1));
    await t.pumpAndSettle();

    await watch('open_reminder_sheet', () async {
      await t.tap(find.byIcon(Icons.notification_add_outlined));
      await t.pumpAndSettle();
    });
    await watch('pick_preset', () async {
      await t.tap(preset.first);
      await t.pumpAndSettle();
    });

    await t.tap(find.byIcon(Icons.notification_add_outlined));
    await t.pumpAndSettle();
    await watch('show_custom_wheel', () async {
      await t.tap(find.byKey(const ValueKey('custom-reminder-toggle')));
      await t.pumpAndSettle();
    });
    await watch('spin_wheel', () async {
      final wheel = find.byType(CupertinoDatePicker);
      for (var i = 0; i < 3; i++) {
        await t.fling(wheel, const Offset(0, -120), 800);
        await t.pumpAndSettle();
      }
    });
    await watch('save_custom', () async {
      await t.tap(find.byKey(const ValueKey('save-custom-reminder')));
      await t.pumpAndSettle();
    });

    await watch('close_note', () async {
      await t.tap(find.byType(BackButton).first);
      await t.pumpAndSettle();
    });
  });
}
