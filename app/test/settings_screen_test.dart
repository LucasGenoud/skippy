import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart';
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

  testWidgets('grid density control renders and updates the store', (
    tester,
  ) async {
    final api = FakeApi();
    final settings = await pumpSettings(tester, api);
    expect(settings.gridDensity, GridDensity.comfortable);

    // All three presets are offered and the current one is described.
    for (final density in GridDensity.values) {
      expect(find.text(density.label), findsOneWidget);
    }
    expect(find.text(GridDensity.comfortable.blurb), findsOneWidget);

    await tester.ensureVisible(find.text('Compact'));
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(settings.gridDensity, GridDensity.compact);
  });
}
