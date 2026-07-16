import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sticky_notes/models/chat.dart';
import 'package:sticky_notes/screens/chat_screen.dart';
import 'package:sticky_notes/screens/settings_screen.dart';
import 'package:sticky_notes/state/notes_store.dart';
import 'package:sticky_notes/state/settings_store.dart';

import 'fake_api.dart';

void main() {
  group('ChatEvent.fromJson', () {
    test('parses every frame type and ignores unknown ones', () {
      final sources = ChatEvent.fromJson({
        'type': 'sources',
        'notes': [
          {'id': 'n1', 'title': 'Groceries'},
          {'id': 'n2'}, // title may be absent
        ],
      });
      expect(sources, isA<ChatSourcesEvent>());
      final list = (sources as ChatSourcesEvent).notes;
      expect(list.length, 2);
      expect(list[0].id, 'n1');
      expect(list[0].title, 'Groceries');
      expect(list[1].title, '');

      final delta = ChatEvent.fromJson({'type': 'delta', 'text': 'hi'});
      expect((delta as ChatDeltaEvent).text, 'hi');

      expect(ChatEvent.fromJson({'type': 'done'}), isA<ChatDoneEvent>());

      final error = ChatEvent.fromJson({'type': 'error', 'message': 'boom'});
      expect((error as ChatErrorEvent).message, 'boom');

      // Forward compatibility: unknown frames are skipped, not crashes.
      expect(ChatEvent.fromJson({'type': 'telemetry'}), isNull);
      expect(ChatEvent.fromJson({}), isNull);
    });
  });

  group('ChatScreen', () {
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

    Widget harness(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: MaterialApp(home: child),
    );

    testWidgets('a turn streams deltas into one bubble with source chips', (
      tester,
    ) async {
      api.chatScript = const [
        ChatSourcesEvent([ChatSource(id: 'n1', title: 'Groceries')]),
        ChatDeltaEvent('You need '),
        ChatDeltaEvent('milk.'),
        ChatDoneEvent(),
      ];
      await tester.pumpWidget(harness(const ChatScreen()));

      await tester.enterText(find.byType(TextField), 'what do I need?');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(api.log, contains('chat:what do I need?'));
      expect(find.text('what do I need?'), findsOneWidget); // user bubble
      expect(find.text('You need milk.'), findsOneWidget); // merged deltas
      expect(find.text('Groceries'), findsOneWidget); // source chip
      // Turn finished: the input is enabled again.
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isTrue,
      );
    });

    testWidgets('a server error before any text becomes an error bubble', (
      tester,
    ) async {
      api.chatScript = const [
        ChatSourcesEvent([]),
        ChatErrorEvent('configure an AI provider in Settings to use chat'),
      ];
      await tester.pumpWidget(harness(const ChatScreen()));

      await tester.enterText(find.byType(TextField), 'hello?');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(
        find.text('configure an AI provider in Settings to use chat'),
        findsOneWidget,
      );
      // Input recovers so the user can retry.
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    });
  });

  group('Settings AI section', () {
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

    Finder aiSwitch(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(SwitchListTile),
    );

    testWidgets('toggles unlock once an AI provider is configured', (
      tester,
    ) async {
      settings.semanticSearchCapable = true;
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('Notes chat'), 200);

      // Unconfigured: both switches inert and explaining why.
      expect(find.text('Configure an AI provider first'), findsNWidgets(2));
      expect(
        tester.widget<SwitchListTile>(aiSwitch('Automatic labeling')).onChanged,
        isNull,
      );
      expect(
        tester.widget<SwitchListTile>(aiSwitch('Notes chat')).onChanged,
        isNull,
      );

      settings.setLlmConfig(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: '',
        model: 'llama3.1',
      );
      await tester.pump();

      // The provider tile may have scrolled off; bring it back to check the
      // configured summary.
      await tester.scrollUntilVisible(
        find.text('AI provider'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('llama3.1 @ localhost'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Notes chat'), 200);
      expect(
        tester.widget<SwitchListTile>(aiSwitch('Automatic labeling')).onChanged,
        isNotNull,
      );
      expect(
        tester.widget<SwitchListTile>(aiSwitch('Notes chat')).onChanged,
        isNotNull,
      );
      // Flush the settings-save debounce so no timers leak.
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('notes chat stays gated on the server capability', (
      tester,
    ) async {
      settings.semanticSearchCapable = false;
      settings.setLlmConfig(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: '',
        model: 'llama3.1',
      );
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('Notes chat'), 200);

      expect(
        find.text('Requires semantic search on this server'),
        findsOneWidget,
      );
      expect(
        tester.widget<SwitchListTile>(aiSwitch('Notes chat')).onChanged,
        isNull,
      );
      // Labeling doesn't need the server: it unlocks regardless.
      expect(
        tester.widget<SwitchListTile>(aiSwitch('Automatic labeling')).onChanged,
        isNotNull,
      );
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('provider dialog saves the config', (tester) async {
      await tester.pumpWidget(harness());
      await tester.scrollUntilVisible(find.text('AI provider'), 200);
      await tester.tap(find.text('AI provider'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Server URL'),
        'https://api.openai.com/v1',
      );
      await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-x');
      await tester.enterText(
        find.widgetWithText(TextField, 'Model'),
        'gpt-5-mini',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.llmBaseUrl, 'https://api.openai.com/v1');
      expect(settings.llmApiKey, 'sk-x');
      expect(settings.llmModel, 'gpt-5-mini');
      expect(settings.llmConfigured, isTrue);
      await tester.pump(const Duration(milliseconds: 700));
    });
  });
}
