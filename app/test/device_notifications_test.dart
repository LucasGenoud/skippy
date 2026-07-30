import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/screens/settings_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/reminder_scheduler.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/util/local_notifications.dart';
import 'package:skippy/util/reminder_schedule.dart';
import 'package:skippy/util/snack.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

/// Stands in for the OS scheduler. The plugin's platform instance is a `late`
/// field only populated by the real plugin registrant, so a method-channel mock
/// isn't enough — the seam has to be above it.
class FakeLocalNotifications extends LocalNotifications {
  bool grant = true;
  bool exact = true;
  int cancelAllCount = 0;
  final List<String> calls = [];

  /// What the "OS" currently holds, keyed by notification id.
  final Map<int, PendingReminder> armed = {};

  @override
  bool get exactAlarmsAllowed => exact;

  @override
  Future<bool> ensureInitialized() async => true;

  @override
  Future<bool> requestPermission() async {
    calls.add('requestPermission');
    return grant;
  }

  @override
  Future<List<PendingReminder>> pending() async => armed.values.toList();

  @override
  Future<void> apply(ReminderScheduleDiff diff) async {
    for (final id in diff.cancel) {
      calls.add('cancel:$id');
      armed.remove(id);
    }
    for (final r in diff.schedule) {
      calls.add('schedule:${r.noteId}');
      armed[r.id] = (
        id: r.id,
        title: r.title,
        body: r.body,
        payload: r.payload,
      );
    }
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCount++;
    calls.add('cancelAll');
    armed.clear();
  }
}

void main() {
  late FakeApi api;
  late NotesStore store;
  late SettingsStore settings;
  late FakeLocalNotifications platform;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
    settings = SettingsStore(api: api);
    platform = FakeLocalNotifications();
  });

  tearDown(() {
    store.dispose();
    settings.dispose();
  });

  group('settings tile', () {
    Widget harness() => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: settings),
        Provider<LocalNotifications>.value(value: platform),
      ],
      child: MaterialApp(
        // showAppSnack posts through the app-wide messenger, as in main.dart.
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: const SettingsScreen(),
      ),
    );

    Finder deviceSwitch() => find.ancestor(
      of: find.text('Reminders on this device'),
      matching: find.byType(SwitchListTile),
    );

    const disclaimer =
        'This device can only ring for reminders it already knows about.';

    Future<void> showTile(WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(
        find.text('Reminders on this device'),
        200,
      );
    }

    testWidgets('granting permission turns it on and shows the caveat', (
      tester,
    ) async {
      await showTile(tester);

      // Opt-in, and the caveat appears only once it is actually on.
      expect(tester.widget<SwitchListTile>(deviceSwitch()).value, isFalse);
      expect(find.textContaining(disclaimer), findsNothing);

      await tester.tap(deviceSwitch());
      await tester.pumpAndSettle();

      expect(settings.deviceNotificationsEnabled, isTrue);
      expect(tester.widget<SwitchListTile>(deviceSwitch()).value, isTrue);
      expect(platform.calls, contains('requestPermission'));
      await tester.scrollUntilVisible(find.textContaining(disclaimer), 200);
      expect(find.textContaining(disclaimer), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('a refused permission leaves the switch off', (tester) async {
      platform.grant = false;
      await showTile(tester);

      await tester.tap(deviceSwitch());
      await tester.pumpAndSettle();

      // Claiming it is on while the OS drops every notification would be worse
      // than staying off, so the setting is never written.
      expect(settings.deviceNotificationsEnabled, isFalse);
      expect(tester.widget<SwitchListTile>(deviceSwitch()).value, isFalse);
      expect(find.textContaining(disclaimer), findsNothing);
      expect(find.textContaining('blocked for Skippy'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('warns when exact alarms are withheld', (tester) async {
      platform.exact = false;
      await showTile(tester);
      await tester.tap(deviceSwitch());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('may be delayed a few minutes'),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 700));
    });
  });

  group('scheduler', () {
    late ReminderScheduler scheduler;

    setUp(() {
      scheduler = ReminderScheduler(
        notes: store,
        settings: settings,
        platform: platform,
      );
    });

    tearDown(() => scheduler.dispose());

    /// The scheduler coalesces bursts of note edits; wait past the debounce.
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      await scheduler.reconcile();
    }

    test('arms nothing while the feature is off', () async {
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Standup',
        reminderAt: DateTime.now().add(const Duration(hours: 2)),
      );
      await store.load();
      scheduler.start();
      await settle();

      expect(platform.armed, isEmpty);
      expect(platform.calls.where((c) => c.startsWith('schedule')), isEmpty);
    });

    test('arms synced reminders once enabled, and re-arms on change', () async {
      settings.setDeviceNotificationsEnabled(true);
      final due = DateTime.now().add(const Duration(hours: 2));
      api.notes['n1'] = serverNote('n1', title: 'Standup', reminderAt: due);
      await store.load();
      scheduler.start();
      await settle();

      expect(platform.armed.length, 1);
      final entry = platform.armed.values.single;
      expect(entry.id, reminderNotificationId('n1'));
      expect(entry.title, 'Standup');
      expect(
        ScheduledReminder.noteIdFromPayload(entry.payload),
        'n1',
      );

      // A second pass with nothing changed must not touch the OS again.
      platform.calls.clear();
      await scheduler.reconcile();
      expect(platform.calls, isEmpty);

      // Moving the reminder re-arms the same id.
      store.setReminder('n1', due.add(const Duration(hours: 1)));
      await settle();
      expect(platform.calls, contains('schedule:n1'));
      expect(platform.armed.length, 1);
    });

    test('clearing a reminder cancels its alarm', () async {
      settings.setDeviceNotificationsEnabled(true);
      api.notes['n1'] = serverNote(
        'n1',
        title: 'Standup',
        reminderAt: DateTime.now().add(const Duration(hours: 2)),
      );
      await store.load();
      scheduler.start();
      await settle();
      expect(platform.armed.length, 1);

      store.setReminder('n1', null);
      await settle();

      expect(platform.armed, isEmpty);
      expect(
        platform.calls,
        contains('cancel:${reminderNotificationId('n1')}'),
      );
    });

    test('turning the feature off clears every alarm exactly once', () async {
      settings.setDeviceNotificationsEnabled(true);
      api.notes['n1'] = serverNote(
        'n1',
        reminderAt: DateTime.now().add(const Duration(hours: 2)),
      );
      await store.load();
      scheduler.start();
      await settle();
      expect(platform.armed.length, 1);

      settings.setDeviceNotificationsEnabled(false);
      await settle();
      expect(platform.armed, isEmpty);
      expect(platform.cancelAllCount, 1);

      // Idle passes while it stays off must not keep calling cancelAll.
      await scheduler.reconcile();
      expect(platform.cancelAllCount, 1);
    });

    test('sign-out drops the account\'s alarms', () async {
      settings.setDeviceNotificationsEnabled(true);
      api.notes['n1'] = serverNote(
        'n1',
        reminderAt: DateTime.now().add(const Duration(hours: 2)),
      );
      await store.load();
      scheduler.start();
      await settle();
      expect(platform.armed.length, 1);

      await scheduler.clear();
      expect(platform.armed, isEmpty);
      expect(platform.cancelAllCount, 1);
    });
  });

  test('the setting round-trips to another device', () async {
    await settings.load();
    expect(settings.deviceNotificationsEnabled, isFalse); // opt-in

    settings.setDeviceNotificationsEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(api.settings['device_notifications'], isTrue);

    final other = SettingsStore(api: api);
    await other.load();
    expect(other.deviceNotificationsEnabled, isTrue);
    other.dispose();
  });
}
