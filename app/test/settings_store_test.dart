import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/theme.dart';

import 'fake_api.dart';

Future<void> settleSave() =>
    Future<void>.delayed(const Duration(milliseconds: 800));

void main() {
  late FakeApi api;
  late SettingsStore settings;

  setUp(() {
    api = FakeApi();
    settings = SettingsStore(api: api);
  });

  tearDown(() => settings.dispose());

  test('defaults are sane before and after loading empty settings', () async {
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.dateFormat, AppDateFormat.dayFirst);
    expect(settings.use24hTime, isTrue);
    expect(settings.gridDensity, GridDensity.comfortable);
    expect(settings.gridWidth, GridWidth.medium);
    expect(settings.palette.length, kDefaultPalette.length);
    await settings.load();
    expect(settings.loaded, isTrue);
    expect(settings.themeMode, ThemeMode.system);
  });

  test('mutations persist to the server and roundtrip', () async {
    await settings.load();
    settings.setThemeMode(ThemeMode.dark);
    settings.setDateFormat(AppDateFormat.numericEU);
    settings.setUse24hTime(true);
    settings.setDefaultListMode(true);
    settings.setGridDensity(GridDensity.compact);
    settings.setGridWidth(GridWidth.full);
    settings.addPaletteColor(
      'Lava',
      const Color(0xFFFF5722),
      const Color(0xFF4E1A0F),
    );
    await settleSave();

    expect(api.settings['theme'], 'dark');
    expect(api.settings['date_format'], 'numericEU');
    expect(api.settings['time_format'], '24h');
    expect(api.settings['default_view'], 'list');
    expect(api.settings['grid_density'], 'compact');
    expect(api.settings['grid_width'], 'full');
    expect(
      (api.settings['palette'] as List).length,
      kDefaultPalette.length + 1,
    );

    // A fresh store (another device) picks everything up.
    final other = SettingsStore(api: api);
    await other.load();
    expect(other.themeMode, ThemeMode.dark);
    expect(other.dateFormat, AppDateFormat.numericEU);
    expect(other.use24hTime, isTrue);
    expect(other.defaultListMode, isTrue);
    expect(other.gridDensity, GridDensity.compact);
    expect(other.gridWidth, GridWidth.full);
    expect(other.palette.last.name, 'Lava');
    expect(other.palette.last.light, const Color(0xFFFF5722));
    other.dispose();
  });

  test('accent color persists, roundtrips, and defaults when absent', () async {
    await settings.load();
    expect(settings.accentColor, kDefaultAccent);

    settings.setAccentColor(const Color(0xFF1A73E8));
    await settleSave();
    expect(api.settings['accent'], '#1A73E8');

    final other = SettingsStore(api: api);
    await other.load();
    expect(other.accentColor, const Color(0xFF1A73E8));
    other.dispose();

    // A payload without (or with a broken) accent falls back to the default.
    api.settings = {'accent': 'nope'};
    final third = SettingsStore(api: api);
    await third.load();
    expect(third.accentColor, kDefaultAccent);
    third.dispose();
  });

  test('malformed settings fall back to defaults per field', () async {
    api.settings = {
      'theme': 'disco',
      'date_format': 'whenever',
      'palette': [
        {'key': 'ok', 'name': 'OK', 'light': '#112233', 'dark': '#445566'},
        {'key': 'broken', 'light': 'not-a-color'},
        'garbage',
      ],
    };
    await settings.load();
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.dateFormat, AppDateFormat.dayFirst);
    // Only the valid palette entry survives.
    expect(settings.palette.single.key, 'ok');
    expect(settings.palette.single.light, const Color(0xFF112233));
  });

  test(
    'resolveColor: custom palette, legacy default keys, unknown keys',
    () async {
      settings.addPaletteColor(
        'Lava',
        const Color(0xFFFF5722),
        const Color(0xFF4E1A0F),
      );
      final lavaKey = settings.palette.last.key;
      expect(
        settings.resolveColor(lavaKey, Brightness.light),
        const Color(0xFFFF5722),
      );
      expect(
        settings.resolveColor(lavaKey, Brightness.dark),
        const Color(0xFF4E1A0F),
      );
      expect(settings.resolveColor('default', Brightness.light), isNull);
      expect(settings.resolveColor('nonsense', Brightness.light), isNull);

      // A note colored 'teal' still resolves after the user removed teal from
      // their palette (legacy fallback keeps old notes colored).
      settings.removePaletteColor('teal');
      expect(settings.resolveColor('teal', Brightness.light), isNotNull);
      await settleSave();
    },
  );

  test('feature availability = server capability AND user toggle', () async {
    // Search service running, transcription not.
    api.capabilities = (semanticSearch: true, audioTranscription: false);
    await settings.load();
    expect(settings.semanticSearchCapable, isTrue);
    expect(settings.audioTranscriptionCapable, isFalse);
    // Both toggles default on, but audio is hidden because its service is down.
    expect(settings.semanticSearchAvailable, isTrue);
    expect(settings.audioNotesAvailable, isFalse);

    // Turning a capable feature off hides it and persists the choice.
    settings.setSemanticSearchEnabled(false);
    expect(settings.semanticSearchAvailable, isFalse);
    await settleSave();
    expect(api.settings['semantic_search'], isFalse);

    // Another device with both services up: the enabled feature is available,
    // the one the user turned off stays hidden.
    api.capabilities = (semanticSearch: true, audioTranscription: true);
    final other = SettingsStore(api: api);
    await other.load();
    expect(other.audioNotesAvailable, isTrue);
    expect(other.semanticSearchAvailable, isFalse);
    other.dispose();
  });

  test('llm config persists, roundtrips, and gates availability', () async {
    api.capabilities = (semanticSearch: true, audioTranscription: false);
    await settings.load();

    // Unconfigured: nothing available, whatever the toggles say.
    expect(settings.llmConfigured, isFalse);
    expect(settings.llmLabelingEnabled, isTrue); // toggles default on
    expect(settings.llmChatEnabled, isTrue);
    expect(settings.autoLabelingAvailable, isFalse);
    expect(settings.notesChatAvailable, isFalse);

    settings.setLlmConfig(
      baseUrl: ' http://localhost:11434/v1 ',
      apiKey: '',
      model: ' llama3.1 ',
    );
    expect(settings.llmConfigured, isTrue);
    expect(settings.autoLabelingAvailable, isTrue);
    expect(settings.notesChatAvailable, isTrue);
    settings.setLlmLabelingEnabled(false);
    expect(settings.autoLabelingAvailable, isFalse);
    await settleSave();

    // The persisted keys are exactly the backend's contract, trimmed.
    expect(api.settings['llm_base_url'], 'http://localhost:11434/v1');
    expect(api.settings['llm_api_key'], '');
    expect(api.settings['llm_model'], 'llama3.1');
    expect(api.settings['llm_labeling'], isFalse);
    expect(api.settings['llm_chat'], isTrue);

    // Another device picks it all up.
    final other = SettingsStore(api: api);
    await other.load();
    expect(other.llmConfigured, isTrue);
    expect(other.llmModel, 'llama3.1');
    expect(other.llmLabelingEnabled, isFalse);
    expect(other.notesChatAvailable, isTrue);
    other.dispose();

    // No semantic search on the server: chat unavailable even when configured.
    api.capabilities = (semanticSearch: false, audioTranscription: false);
    final third = SettingsStore(api: api);
    await third.load();
    expect(third.llmConfigured, isTrue);
    expect(third.notesChatAvailable, isFalse);
    expect(third.autoLabelingAvailable, isFalse); // labeling was toggled off
    third.dispose();
  });

  test('server-managed keys override, lock, and hide secrets', () async {
    // The user's own doc carries a stale endpoint + key; the server pins its
    // own base URL + model + a secret key, and forces chat off.
    api.settings = {
      'llm_base_url': 'http://user/v1',
      'llm_api_key': 'sk-user',
      'llm_model': 'user-model',
    };
    api.managedSettings = {
      'llm_base_url': const ManagedSetting(secret: false, value: 'http://managed/v1'),
      'llm_api_key': const ManagedSetting(secret: true),
      'llm_model': const ManagedSetting(secret: false, value: 'managed-model'),
      'llm_chat': const ManagedSetting(secret: false, value: false),
    };
    await settings.load();

    // Managed values win over the user's document.
    expect(settings.llmBaseUrl, 'http://managed/v1');
    expect(settings.llmModel, 'managed-model');
    // Secret is never held client-side, even though the user doc had one.
    expect(settings.llmApiKey, '');
    // Managed toggle reflected; the unmanaged one keeps its default.
    expect(settings.llmChatEnabled, isFalse);
    expect(settings.llmLabelingEnabled, isTrue);

    // Locked keys report as managed; untouched ones don't.
    expect(settings.isManaged('llm_base_url'), isTrue);
    expect(settings.isManaged('llm_api_key'), isTrue);
    expect(settings.isManaged('llm_chat'), isTrue);
    expect(settings.isManaged('llm_labeling'), isFalse);

    // Still counts as configured (managed base+model populate the fields).
    expect(settings.llmConfigured, isTrue);
  });

  test('no managed settings leaves everything user-editable', () async {
    api.settings = {'llm_base_url': 'http://user/v1', 'llm_model': 'm'};
    await settings.load();
    expect(settings.managed, isEmpty);
    expect(settings.isManaged('llm_base_url'), isFalse);
    expect(settings.llmBaseUrl, 'http://user/v1');
  });

  test('date and time formats follow preferences', () {
    final dt = DateTime(2026, 7, 15, 18, 5);
    expect(settings.formatDate(dt), '15 Jul 2026');
    expect(settings.formatClock(dt), '18:05');

    settings.setDateFormat(AppDateFormat.numericEU);
    settings.setUse24hTime(true);
    expect(settings.formatDate(dt), '15.07.2026');
    expect(settings.formatClock(dt), '18:05');

    settings.setDateFormat(AppDateFormat.iso);
    expect(settings.formatDate(dt), '2026-07-15');

    final today = DateTime.now().copyWith(hour: 9, minute: 30);
    expect(settings.reminderLabel(today), 'Today 09:30');
  });
}
