import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticky_notes/state/settings_store.dart';

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
    expect(settings.dateFormat, AppDateFormat.monthFirst);
    expect(settings.use24hTime, isFalse);
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
    expect(other.palette.last.name, 'Lava');
    expect(other.palette.last.light, const Color(0xFFFF5722));
    other.dispose();
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
    expect(settings.dateFormat, AppDateFormat.monthFirst);
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

  test('date and time formats follow preferences', () {
    final dt = DateTime(2026, 7, 15, 18, 5);
    expect(settings.formatDate(dt), 'Jul 15, 2026');
    expect(settings.formatClock(dt), '6:05 PM');

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
