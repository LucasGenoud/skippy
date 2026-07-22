import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/settings_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';

import 'fake_api.dart';

/// Pump the Settings screen with a loaded settings store (its managed map is
/// whatever the FakeApi returns) and the notes store the export section needs.
Future<SettingsStore> pumpSettings(WidgetTester tester, FakeApi api) async {
  // Tall surface so the whole settings list builds (no lazy off-screen tiles).
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final settings = SettingsStore(api: api);
  await settings.load();
  final notes = NotesStore(api: api, currentUserId: 'u-me');
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: notes),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  testWidgets('server-managed LLM fields are locked in the dialog', (
    tester,
  ) async {
    final api = FakeApi();
    api.managedSettings = {
      'llm_base_url': const ManagedSetting(secret: false, value: 'http://managed/v1'),
      'llm_api_key': const ManagedSetting(secret: true),
    };
    await pumpSettings(tester, api);

    // The AI provider row flags that something is server-managed.
    expect(find.text('Managed by the server'), findsWidgets);

    // Open the config dialog.
    await tester.ensureVisible(find.text('AI provider'));
    await tester.tap(find.text('AI provider'));
    await tester.pumpAndSettle();

    // The managed endpoint field is disabled; the untouched model field is not.
    final url = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Server URL').first,
    );
    expect(url.enabled, isFalse);
    final model = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Model').first,
    );
    expect(model.enabled, isTrue);

    // The secret key field is masked and locked, never carrying a value.
    expect(find.text('•••••• (set by the server)'), findsOneWidget);
    expect(find.text('Set by the server'), findsWidgets);
  });

  testWidgets('with nothing managed, all LLM fields are editable', (
    tester,
  ) async {
    final api = FakeApi();
    await pumpSettings(tester, api);
    expect(find.text('Managed by the server'), findsNothing);

    await tester.ensureVisible(find.text('AI provider'));
    await tester.tap(find.text('AI provider'));
    await tester.pumpAndSettle();
    for (final label in const ['Server URL', 'API key', 'Model']) {
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, label).first,
      );
      expect(field.enabled, isTrue, reason: '$label should be editable');
    }
  });

  testWidgets('embedding stats tile shows diagnostics and triggers a reindex', (
    tester,
  ) async {
    final api = FakeApi();
    final now = DateTime.utc(2026);
    api.notes['a'] = Note(id: 'a', createdAt: now, updatedAt: now);
    api.notes['b'] = Note(id: 'b', createdAt: now, updatedAt: now);
    await pumpSettings(tester, api);

    // Diagnostics from the (fake) index are rendered.
    expect(find.text('Embedding index'), findsOneWidget);
    expect(find.text('fake-embedder'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);

    // The button re-embeds every note and shows a progress bar.
    api.reindexStatus = (running: false, done: 2, total: 2);
    await tester.ensureVisible(find.text('Re-run embeddings'));
    await tester.tap(find.text('Re-run embeddings'));
    await tester.pump(); // reindexEmbeddings resolves, progress starts
    expect(api.log, contains('reindexEmbeddings'));
    expect(api.reindexedCount, 2);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('0 / 2 embedded'), findsOneWidget);

    // The poll reports completion; the bar then clears and stats refresh.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(api.log, contains('fetchReindexStatus'));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('embedding stats tile is hidden when search is unavailable', (
    tester,
  ) async {
    final api = FakeApi();
    api.capabilities = (semanticSearch: false, audioTranscription: false);
    await pumpSettings(tester, api);
    expect(find.text('Embedding index'), findsNothing);
  });

  testWidgets('grid layout controls render and update the store', (
    tester,
  ) async {
    final api = FakeApi();
    final settings = await pumpSettings(tester, api);
    expect(settings.gridDensity, GridDensity.comfortable);
    expect(settings.gridWidth, GridWidth.medium);

    // Both control's presets are offered.
    for (final density in GridDensity.values) {
      expect(find.text(density.label), findsOneWidget);
    }
    for (final width in GridWidth.values) {
      expect(find.text(width.label), findsOneWidget);
    }
    expect(find.text(GridDensity.comfortable.blurb), findsOneWidget);

    await tester.ensureVisible(find.text('Compact'));
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(settings.gridDensity, GridDensity.compact);

    await tester.ensureVisible(find.text('Full'));
    await tester.tap(find.text('Full'));
    await tester.pumpAndSettle();
    expect(settings.gridWidth, GridWidth.full);
  });

  testWidgets('date format uses the standard form dropdown', (tester) async {
    final api = FakeApi();
    final settings = await pumpSettings(tester, api);

    expect(settings.dateFormat, AppDateFormat.dayFirst);
    expect(settings.use24hTime, isTrue);

    final picker = find.byType(DropdownButtonFormField<AppDateFormat>);
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();

    expect(find.text('Day.month.year (15.07.2026)'), findsOneWidget);

    await tester.tap(find.text('Day.month.year (15.07.2026)'));
    await tester.pumpAndSettle();
    expect(settings.dateFormat, AppDateFormat.numericEU);
    await tester.pump(const Duration(milliseconds: 600));
  });
}
