import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/notify_channels.dart';
import 'package:skippy/screens/settings_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';

import 'fake_api.dart';

Future<void> settleSave() =>
    Future<void>.delayed(const Duration(milliseconds: 800));

void main() {
  group('notify channel specs', () {
    test('configured needs every mandatory field', () {
      final ntfy = kNotifyChannels.firstWhere((c) => c.key == 'ntfy');
      final telegram = kNotifyChannels.firstWhere((c) => c.key == 'telegram');

      expect(ntfy.configuredIn({}), isFalse);
      expect(ntfy.configuredIn({'ntfy_url': ' '}), isFalse);
      // The token is optional.
      expect(ntfy.configuredIn({'ntfy_url': 'https://ntfy.sh/t'}), isTrue);

      expect(telegram.configuredIn({'telegram_bot_token': 'x'}), isFalse);
      expect(
        telegram.configuredIn({
          'telegram_bot_token': 'x',
          'telegram_chat_id': '42',
        }),
        isTrue,
      );
    });
  });

  group('SettingsStore notifications', () {
    late FakeApi api;
    late SettingsStore settings;

    setUp(() {
      api = FakeApi();
      settings = SettingsStore(api: api);
    });

    tearDown(() => settings.dispose());

    test('notify config persists, roundtrips, and gates the toggle', () async {
      await settings.load();

      expect(settings.notifyConfigured, isFalse);
      expect(settings.reminderNotificationsEnabled, isTrue); // defaults on

      settings.setNotifyValues({
        'ntfy_url': ' https://ntfy.sh/mine ',
        'telegram_bot_token': '123:abc',
        'telegram_chat_id': '42',
      });
      expect(settings.notifyConfigured, isTrue);
      expect(settings.configuredNotifyChannels, ['ntfy', 'Telegram']);
      settings.setReminderNotificationsEnabled(false);
      await settleSave();

      // The persisted keys are exactly the backend connectors' contract,
      // trimmed; absent fields still serialize (toJson rebuilds the doc).
      expect(api.settings['ntfy_url'], 'https://ntfy.sh/mine');
      expect(api.settings['ntfy_token'], '');
      expect(api.settings['telegram_bot_token'], '123:abc');
      expect(api.settings['telegram_chat_id'], '42');
      expect(api.settings['reminder_notifications'], isFalse);

      // Another device picks it all up.
      final other = SettingsStore(api: api);
      await other.load();
      expect(other.notifyConfigured, isTrue);
      expect(other.notifyValues['ntfy_url'], 'https://ntfy.sh/mine');
      expect(other.reminderNotificationsEnabled, isFalse);
      other.dispose();
    });
  });

  group('Settings Notifications section', () {
    late FakeApi api;
    late NotesStore store;
    late SettingsStore settings;

    setUp(() {
      api = FakeApi();
      store = NotesStore(api: api, currentUserId: 'u-me');
      settings = SettingsStore(api: api);
    });

    tearDown(() {
      store.dispose();
      settings.dispose();
    });

    Widget harness() => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

    Finder notifySwitch() => find.ancestor(
      of: find.text('Reminder notifications'),
      matching: find.byType(SwitchListTile),
    );

    testWidgets('toggle unlocks once a channel is configured', (tester) async {
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('Reminder notifications'), 200);

      expect(find.text('Configure a channel first'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(notifySwitch()).onChanged, isNull);

      settings.setNotifyValues({'ntfy_url': 'https://ntfy.sh/mine'});
      await tester.pump();

      expect(
        tester.widget<SwitchListTile>(notifySwitch()).onChanged,
        isNotNull,
      );
      // The tile summarizes what's configured.
      await tester.scrollUntilVisible(
        find.text('Notification channels'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('ntfy'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('channel dialog saves the config', (tester) async {
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('Notification channels'), 200);
      await tester.ensureVisible(find.text('Notification channels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notification channels'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Topic URL'),
        'https://ntfy.sh/mine',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Chat ID'), '4242');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.notifyValues['ntfy_url'], 'https://ntfy.sh/mine');
      // Telegram stays unconfigured (chat id alone lacks the bot token).
      expect(settings.configuredNotifyChannels, ['ntfy']);
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('send test probes the field values, not saved settings', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('Notification channels'), 200);
      await tester.ensureVisible(find.text('Notification channels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notification channels'));
      await tester.pumpAndSettle();

      // Nothing configured yet: the probe button is inert.
      final sendTest = find.widgetWithText(OutlinedButton, 'Send test');
      expect(tester.widget<OutlinedButton>(sendTest).onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'Topic URL'),
        'https://ntfy.sh/probe',
      );
      await tester.pump();
      await tester.tap(sendTest);
      await tester.pumpAndSettle();

      expect(api.lastNotifyTestConfig?['ntfy_url'], 'https://ntfy.sh/probe');
      expect(find.text('Sent, check your device'), findsOneWidget);
      // Nothing was saved by testing alone.
      expect(settings.notifyConfigured, isFalse);

      // Failures surface the channel-prefixed reason.
      api.notifyTestOk = false;
      await tester.tap(sendTest);
      await tester.pumpAndSettle();
      expect(find.text('ntfy: boom'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    /// Open the channel dialog from the settings screen.
    Future<void> openDialog(WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('Notification channels'), 200);
      await tester.ensureVisible(find.text('Notification channels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notification channels'));
      await tester.pumpAndSettle();
    }

    Finder field(String key) => find.byKey(ValueKey('notify-field-$key'));

    /// The dialog scrolls its own field list, so reaching a field near the
    /// bottom means scrolling that list rather than the settings page.
    Future<void> scrollDialogTo(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(
        target,
        120,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('email is configured with a server and an address', (
      tester,
    ) async {
      await openDialog(tester);
      await scrollDialogTo(tester, field('smtp_to'));

      await tester.enterText(field('smtp_host'), 'smtp.example.com');
      await tester.enterText(field('smtp_username'), 'bot@example.com');
      await tester.enterText(field('smtp_to'), 'ada@example.com');
      await tester.pump();

      // The security dropdown starts on what a blank value means, and the
      // port is left to follow whatever it is set to.
      await scrollDialogTo(tester, field('smtp_security'));
      await tester.tap(field('smtp_security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('STARTTLS (port 587)').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.notifyValues['smtp_host'], 'smtp.example.com');
      expect(settings.notifyValues['smtp_security'], 'starttls');
      expect(settings.notifyValues['smtp_port'], '');
      // No sender was given, so the username stands in and the channel is
      // complete, exactly as the connector reads it.
      expect(settings.configuredNotifyChannels, ['Email']);
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('a server-pinned mail server locks its fields', (tester) async {
      api.managedSettings = {
        'smtp_host': const ManagedSetting(secret: false, value: 'mail.host'),
        'smtp_password': const ManagedSetting(secret: true),
      };
      await settings.load();
      await openDialog(tester);
      await scrollDialogTo(tester, field('smtp_password'));

      // Pinned fields carry the server's value and cannot be edited; the
      // secret shows a placeholder because its value never reaches the client.
      expect(
        tester.widget<TextField>(field('smtp_host')).controller?.text,
        'mail.host',
      );
      expect(tester.widget<TextField>(field('smtp_host')).enabled, isFalse);
      expect(tester.widget<TextField>(field('smtp_password')).enabled, isFalse);
      expect(find.text('•••••• (set by the server)'), findsOneWidget);
      // The user's own field is still theirs to fill in.
      expect(tester.widget<TextField>(field('smtp_to')).enabled, isTrue);
      await tester.pump(const Duration(milliseconds: 700));
    });
  });
}
