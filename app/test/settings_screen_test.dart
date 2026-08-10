import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/screens/settings_screen.dart';
import 'package:skippy/state/auth_store.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/util/backup.dart';
import 'package:skippy/util/app_version.dart';
import 'package:skippy/widgets/settings/export_section.dart';
import 'package:skippy/widgets/settings/location_map_picker.dart';

import 'fake_api.dart';

/// Pump the Settings screen with a loaded settings store (its managed map is
/// whatever the FakeApi returns) and the notes store the export section needs.
Future<SettingsStore> pumpSettings(
  WidgetTester tester,
  FakeApi api, {
  AuthStore? authStore,
}) async {
  // Tall surface so the whole settings list builds (no lazy off-screen tiles).
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final settings = SettingsStore(api: api);
  await settings.load();
  final notes = NotesStore(api: api, currentUserId: 'u-me');
  final auth =
      authStore ??
      (AuthStore(api: ApiClient(baseUrl: 'http://unused'))..user = api.account);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: notes),
        ChangeNotifierProvider.value(value: auth),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  testWidgets('settings shows client and server build versions', (
    tester,
  ) async {
    await pumpSettings(tester, FakeApi());

    expect(find.text('Client version'), findsOneWidget);
    expect(find.text(clientVersion), findsOneWidget);
    expect(find.text('Server version'), findsOneWidget);
    expect(find.text('test-server'), findsOneWidget);
  });

  testWidgets('backup and restore actions are available in settings', (
    tester,
  ) async {
    await pumpSettings(tester, FakeApi());

    expect(find.text('Create backup'), findsOneWidget);
    expect(find.text('Restore backup'), findsOneWidget);
  });

  testWidgets(
    'restore dialog lists backup workspaces and requires a selection',
    (tester) async {
      const backup = BackupBundle(
        workspaces: [
          BackupWorkspace(
            id: 'w-home',
            name: 'Home',
            isDefault: true,
            labels: [],
            stages: [],
            notes: [],
          ),
          BackupWorkspace(
            id: 'w-work',
            name: 'Work',
            isDefault: false,
            labels: [BackupLabel(id: 'l-work', name: 'Urgent')],
            stages: [BackupStage(id: 's-doing', name: 'Doing')],
            notes: [],
          ),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: RestoreBackupDialog(backup: backup)),
        ),
      );

      expect(find.text('Choose workspaces to restore'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Replace and restore'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(2));

      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Replace and restore'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('account settings expose name, email, and password editors', (
    tester,
  ) async {
    final api = FakeApi();
    await pumpSettings(tester, api);

    expect(find.text('Me Example'), findsOneWidget);
    expect(find.text('me@example.test'), findsOneWidget);
    expect(find.text('Change your sign-in password'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('DANGER ZONE'), findsOneWidget);
    expect(find.text('Create backup'), findsOneWidget);
    expect(find.text('Restore backup'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Delete account')).dy,
      greaterThan(tester.getTopLeft(find.text('Keyboard shortcuts')).dy),
    );

    await tester.tap(find.text('Email').first);
    await tester.pumpAndSettle();
    expect(find.text('Change email'), findsOneWidget);
    expect(find.text('Current password'), findsOneWidget);
    expect(find.text('New email'), findsOneWidget);
  });

  testWidgets('account deletion requires a password and clears local state', (
    tester,
  ) async {
    late http.Request deletion;
    final client = MockClient((request) async {
      deletion = request;
      return http.Response('', 204, request: request);
    });
    final apiClient = ApiClient(
      baseUrl: 'http://server.example',
      httpClient: client,
    )..token = 'session-token';
    final auth = AuthStore(api: apiClient)
      ..user = const AuthUser(
        id: 'u-me',
        name: 'Me Example',
        email: 'me@example.test',
      )
      ..status = AuthStatus.signedIn;
    final cacheKey = notesCacheKey(apiClient.baseUrl, 'u-me');
    SharedPreferences.setMockInitialValues({
      'notes_cache_$cacheKey': '{"notes":[]}',
    });
    await pumpSettings(tester, FakeApi(), authStore: auth);

    await tester.tap(find.text('Delete account').first);
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Current password'),
      'hunter22',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete account'));
    await tester.pumpAndSettle();

    expect(deletion.method, 'DELETE');
    expect(deletion.url.path, '/api/auth/me');
    expect(deletion.headers['authorization'], 'Bearer session-token');
    expect(deletion.body, '{"current_password":"hunter22"}');
    expect(auth.status, AuthStatus.signedOut);
    expect(auth.user, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('notes_cache_$cacheKey'), isNull);
  });

  testWidgets('LLM fields are editable', (tester) async {
    final api = FakeApi();
    await pumpSettings(tester, api);

    await tester.ensureVisible(find.text('AI provider'));
    await tester.tap(find.text('AI provider'));
    await tester.pumpAndSettle();
    for (final label in const ['Server URL', 'API key', 'Model']) {
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, label).first,
      );
      expect(field.enabled, isNot(false), reason: '$label should be editable');
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
    api.capabilities = (
      semanticSearch: false,
      audioTranscription: false,
      imageOcr: false,
      serverVersion: 'test-server',
    );
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

  testWidgets('saved locations can be created in settings', (tester) async {
    final settings = await pumpSettings(tester, FakeApi());

    await tester.ensureVisible(find.text('Add saved location'));
    await tester.tap(find.text('Add saved location'));
    await tester.pumpAndSettle();

    // The place is picked on a map; the coordinate fields are the precise
    // way to say the same thing.
    expect(find.byType(LocationMapPicker), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Home');
    await tester.enterText(
      find.widgetWithText(TextField, 'Latitude'),
      '46.948',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Longitude'),
      '7.4474',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(settings.savedLocations.single.name, 'Home');
    expect(find.text('Home'), findsOneWidget);
    expect(find.textContaining('150 m radius'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });
}
