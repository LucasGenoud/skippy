import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/models/notify_channels.dart';
import 'package:skippy/models/saved_location.dart';
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

  test('dispose stops an in-flight load before the next request', () async {
    final gate = api.fetchCapabilitiesGate = Completer<void>();
    final loading = settings.load();
    await pumpEventQueue();

    settings.dispose();
    gate.complete();
    await loading;

    expect(api.log, ['fetchCapabilities']);
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

  group('saved smart views', () {
    test('persist, roundtrip, and survive a malformed entry', () async {
      await settings.load();
      final work = settings.addSavedView(
        name: 'Open work',
        query: 'label:work is:open',
        icon: 'work',
        color: '#1A73E8',
      );
      settings.addSavedView(name: 'Pinned', query: 'is:pinned');
      await settleSave();

      expect((api.settings['saved_views'] as List).length, 2);

      final other = SettingsStore(api: api);
      await other.load();
      expect(other.savedViews.map((v) => v.name), ['Open work', 'Pinned']);
      expect(other.savedViewById(work.id)?.query, 'label:work is:open');
      expect(other.savedViewById(work.id)?.icon, 'work');
      expect(other.savedViewById(work.id)?.color, '#1A73E8');
      other.dispose();

      // An entry missing a query (or a name, or an id) can't be run or shown,
      // so it is dropped rather than surfacing a broken sidebar row.
      api.settings = {
        'saved_views': [
          {'id': 'a', 'name': 'Fine', 'query': 'is:pinned'},
          {'id': 'b', 'name': 'No query'},
          'garbage',
        ],
      };
      final third = SettingsStore(api: api);
      await third.load();
      expect(third.savedViews.map((v) => v.id), ['a']);
      third.dispose();
    });

    test('edit clears an icon, delete removes it, reorder moves it', () async {
      await settings.load();
      final view = settings.addSavedView(
        name: 'Work',
        query: 'label:work',
        icon: 'work',
      );
      final other = settings.addSavedView(name: 'Pinned', query: 'is:pinned');

      settings.updateSavedView(
        view.id,
        name: 'Work stuff',
        query: 'label:work',
      );
      expect(settings.savedViewById(view.id)?.name, 'Work stuff');
      expect(settings.savedViewById(view.id)?.icon, isNull);

      settings.reorderSavedViews(0, 1);
      expect(settings.savedViews.map((v) => v.id), [other.id, view.id]);

      settings.removeSavedView(view.id);
      expect(settings.savedViews.map((v) => v.id), [other.id]);
      await settleSave();
      expect((api.settings['saved_views'] as List).length, 1);
    });
  });

  group('saved locations', () {
    test('places and personal reminders persist and roundtrip', () async {
      await settings.load();
      final home = settings.addSavedLocation(
        name: 'Home',
        latitude: 46.948,
        longitude: 7.4474,
        radiusMeters: 150,
      );
      expect(
        settings.setLocationReminder(
          'note-1',
          home.id,
          LocationReminderTrigger.arrive,
        ),
        isTrue,
      );
      await settleSave();

      final other = SettingsStore(api: api);
      await other.load();
      expect(other.savedLocations.single.name, 'Home');
      expect(other.savedLocations.single.latitude, 46.948);
      expect(
        other.locationReminderForNote('note-1')?.trigger,
        LocationReminderTrigger.arrive,
      );
      expect(other.locationReminderForNote('note-1')?.repeats, isFalse);
      other.dispose();
    });

    test('a repeating reminder stays repeating across a reload', () async {
      await settings.load();
      final home = settings.addSavedLocation(
        name: 'Home',
        latitude: 46.948,
        longitude: 7.4474,
        radiusMeters: 150,
      );
      settings.setLocationReminder(
        'note-1',
        home.id,
        LocationReminderTrigger.arrive,
        repeats: true,
      );
      await settleSave();

      final other = SettingsStore(api: api);
      await other.load();
      final reminder = other.locationReminderForNote('note-1');
      expect(reminder?.repeats, isTrue);
      expect(reminder?.label, 'Every time I arrive');
      other.dispose();
    });

    test('a reminder saved before repeating existed stays one-shot', () {
      final reminder = LocationReminder.fromJson({
        'note_id': 'note-1',
        'location_id': 'home',
        'trigger': 'leave',
      });
      expect(reminder?.repeats, isFalse);
      expect(reminder?.label, 'When I leave');
    });

    test('deleting a place removes reminders that reference it', () async {
      final work = settings.addSavedLocation(
        name: 'Work',
        latitude: 47.3769,
        longitude: 8.5417,
        radiusMeters: 200,
      );
      settings.setLocationReminder(
        'note-1',
        work.id,
        LocationReminderTrigger.leave,
      );

      settings.removeSavedLocation(work.id);

      expect(settings.savedLocations, isEmpty);
      expect(settings.locationReminders, isEmpty);
    });

    test('malformed places and orphan reminders are ignored', () async {
      api.settings = {
        'saved_locations': [
          {
            'id': 'home',
            'name': 'Home',
            'latitude': 46.9,
            'longitude': 7.4,
            'radius_meters': 150,
          },
          {'id': 'broken', 'name': 'Broken', 'latitude': 999, 'longitude': 0},
        ],
        'location_reminders': [
          {'note_id': 'a', 'location_id': 'home', 'trigger': 'arrive'},
          {'note_id': 'b', 'location_id': 'missing', 'trigger': 'leave'},
        ],
      };

      await settings.load();

      expect(settings.savedLocations.map((location) => location.id), ['home']);
      expect(settings.locationReminders.map((reminder) => reminder.noteId), [
        'a',
      ]);
    });
  });

  test('top-bar theme cycle includes the system default', () {
    expect(settings.themeMode, ThemeMode.system);
    settings.cycleThemeMode();
    expect(settings.themeMode, ThemeMode.light);
    settings.cycleThemeMode();
    expect(settings.themeMode, ThemeMode.dark);
    settings.cycleThemeMode();
    expect(settings.themeMode, ThemeMode.system);
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

  test(
    'search is capability-gated while audio notes are always available',
    () async {
      // Search service running, transcription not.
      api.capabilities = (
        semanticSearch: true,
        audioTranscription: false,
        imageOcr: false,
        passwordReset: false,
        serverVersion: 'test-server',
      );
      await settings.load();
      expect(settings.semanticSearchCapable, isTrue);
      expect(settings.audioTranscriptionCapable, isFalse);
      expect(settings.imageOcrCapable, isFalse);
      // Audio recording remains available without Whisper; only transcription is
      // disabled. Search still requires its backing service.
      expect(settings.semanticSearchAvailable, isTrue);
      expect(settings.audioNotesAvailable, isTrue);

      // Turning a capable feature off hides it and persists the choice.
      settings.setSemanticSearchEnabled(false);
      expect(settings.semanticSearchAvailable, isFalse);
      await settleSave();
      expect(api.settings['semantic_search'], isFalse);

      // Another device with every service up keeps audio available, while the
      // user-disabled search feature remains hidden.
      api.capabilities = (
        semanticSearch: true,
        audioTranscription: true,
        imageOcr: true,
        passwordReset: false,
        serverVersion: 'test-server',
      );
      final other = SettingsStore(api: api);
      await other.load();
      expect(other.audioNotesAvailable, isTrue);
      expect(other.semanticSearchAvailable, isFalse);
      // Reading pictures for text has no user toggle: the server either does
      // it or it does not.
      expect(other.imageOcrCapable, isTrue);
      other.dispose();
    },
  );

  test('llm config persists, roundtrips, and gates availability', () async {
    api.capabilities = (
      semanticSearch: true,
      audioTranscription: false,
      imageOcr: false,
      passwordReset: false,
      serverVersion: 'test-server',
    );
    await settings.load();

    // Unconfigured: nothing available, whatever the toggles say.
    expect(settings.llmConfigured, isFalse);
    expect(settings.llmLabelingEnabled, isTrue); // toggles default on
    expect(settings.llmChatEnabled, isTrue);
    expect(settings.llmWritingEnabled, isFalse);
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
    expect(settings.noteWritingAvailable, isFalse);
    settings.setLlmLabelingEnabled(false);
    settings.setLlmWritingEnabled(true);
    expect(settings.autoLabelingAvailable, isFalse);
    await settleSave();

    // The persisted keys are exactly the backend's contract, trimmed.
    expect(api.settings['llm_base_url'], 'http://localhost:11434/v1');
    expect(api.settings['llm_api_key'], '');
    expect(api.settings['llm_model'], 'llama3.1');
    expect(api.settings['llm_labeling'], isFalse);
    expect(api.settings['llm_chat'], isTrue);
    expect(api.settings['llm_writing'], isTrue);

    // Another device picks it all up.
    final other = SettingsStore(api: api);
    await other.load();
    expect(other.llmConfigured, isTrue);
    expect(other.llmModel, 'llama3.1');
    expect(other.llmLabelingEnabled, isFalse);
    expect(other.notesChatAvailable, isTrue);
    expect(other.noteWritingAvailable, isTrue);
    other.dispose();

    // No semantic search on the server: chat unavailable even when configured.
    api.capabilities = (
      semanticSearch: false,
      audioTranscription: false,
      imageOcr: false,
      passwordReset: false,
      serverVersion: 'test-server',
    );
    final third = SettingsStore(api: api);
    await third.load();
    expect(third.llmConfigured, isTrue);
    expect(third.notesChatAvailable, isFalse);
    expect(third.autoLabelingAvailable, isFalse); // labeling was toggled off
    third.dispose();
  });

  test('LLM settings belong to the user', () async {
    api.settings = {'llm_base_url': 'http://user/v1', 'llm_model': 'm'};
    await settings.load();
    expect(settings.llmBaseUrl, 'http://user/v1');
    expect(settings.llmModel, 'm');
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

  test('server-managed keys override, lock, and hide secrets', () async {
    // The user's own doc carries a stale endpoint + key; the server pins its
    // own base URL + model + a secret key, and forces chat off.
    api.settings = {
      'llm_base_url': 'http://user/v1',
      'llm_api_key': 'sk-user',
      'llm_model': 'user-model',
    };
    api.managedSettings = {
      'llm_base_url': const ManagedSetting(
        secret: false,
        value: 'http://managed/v1',
      ),
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
    expect(settings.isManaged('llm_labeling'), isFalse);
  });

  test('a managed key never overwrites the user\'s own stored value', () async {
    api.settings = {
      'llm_base_url': 'http://user/v1',
      'llm_api_key': 'sk-user',
      'llm_model': 'user-model',
      'llm_chat': true,
    };
    api.managedSettings = {
      'llm_base_url': const ManagedSetting(
        secret: false,
        value: 'http://managed/v1',
      ),
      'llm_api_key': const ManagedSetting(secret: true),
      'llm_chat': const ManagedSetting(secret: false, value: false),
    };
    await settings.load();

    // Saving any unrelated setting rewrites the whole document. The pinned
    // keys must go back as the user had them, or un-pinning the env var later
    // would hand them the server's config (or, for the key, nothing at all).
    settings.setThemeMode(ThemeMode.dark);
    await settleSave();

    expect(api.settings['llm_base_url'], 'http://user/v1');
    expect(api.settings['llm_api_key'], 'sk-user');
    expect(api.settings['llm_chat'], isTrue);
    // Unmanaged keys still persist what the store holds.
    expect(api.settings['llm_model'], 'user-model');
    expect(api.settings['theme'], 'dark');
  });

  test('a server-managed mail server completes the email channel', () async {
    // The deployment runs the mail server; the user supplies only their own
    // address. Nothing else about email is theirs to fill in.
    api.settings = {'smtp_to': 'ada@example.test'};
    api.managedSettings = {
      'smtp_host': const ManagedSetting(secret: false, value: 'mail.host'),
      'smtp_security': const ManagedSetting(secret: false, value: 'starttls'),
      'smtp_from': const ManagedSetting(secret: false, value: 'bot@host'),
      'smtp_password': const ManagedSetting(secret: true),
    };
    await settings.load();

    // The dialog shows what will actually be used…
    expect(settings.notifyValues['smtp_host'], 'mail.host');
    expect(settings.notifyValues['smtp_security'], 'starttls');
    // …except the secret, which the server never sends and the client must
    // never hold.
    expect(settings.notifyValues['smtp_password'], '');
    expect(settings.isManaged('smtp_host'), isTrue);
    expect(settings.isManaged('smtp_to'), isFalse);

    // The channel counts as configured even though the user set one field.
    expect(settings.notifyConfigured, isTrue);
    expect(settings.configuredNotifyChannels, ['Email']);
  });

  test('pinning a mail server does not erase the user\'s own', () async {
    api.settings = {
      'smtp_host': 'mail.mine',
      'smtp_password': 'my-password',
      'smtp_to': 'ada@example.test',
    };
    api.managedSettings = {
      'smtp_host': const ManagedSetting(secret: false, value: 'mail.host'),
      'smtp_password': const ManagedSetting(secret: true),
    };
    await settings.load();

    settings.setThemeMode(ThemeMode.dark);
    await settleSave();

    // Same rule as the LLM keys: un-pinning the env var later has to hand the
    // user their own mail server back, not a copy of the server's.
    expect(api.settings['smtp_host'], 'mail.mine');
    expect(api.settings['smtp_password'], 'my-password');
    expect(api.settings['smtp_to'], 'ada@example.test');
  });

  test('the email channel needs a sender, or a username to stand in', () {
    final email = kNotifyChannels.firstWhere((c) => c.key == 'email');
    expect(
      email.configuredIn({'smtp_host': 'h', 'smtp_to': 'a@b.test'}),
      isFalse,
    );
    // The connector falls back to the account it authenticates as, and the
    // UI has to agree or it would refuse to send a test the server accepts.
    expect(
      email.configuredIn({
        'smtp_host': 'h',
        'smtp_to': 'a@b.test',
        'smtp_username': 'bot@b.test',
      }),
      isTrue,
    );
    expect(
      email.configuredIn({
        'smtp_host': 'h',
        'smtp_to': 'a@b.test',
        'smtp_from': 'bot@b.test',
      }),
      isTrue,
    );
  });
}
