import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/api/api_client.dart' show ManagedSetting;
import 'package:skippy/models/note.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/screens/workspace_settings_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';

import 'fake_api.dart';
import 'widget_test.dart' show homeApp;

const _team = 'w-team';

/// A workspace Ada owns and the test user belongs to.
const _adasWorkspace = Workspace(
  id: _team,
  name: 'Family',
  owner: UserRef(id: 'u-ada', name: 'Ada'),
  members: [UserRef(id: 'u-me', name: 'Me Example')],
  ai: WorkspaceAi(providerReady: true, switches: AiSwitches(labeling: false)),
);

void main() {
  late FakeApi api;
  late NotesStore store;
  late SettingsStore settings;

  setUp(() {
    api = FakeApi();
    api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
      ai: const WorkspaceAi(providerReady: true),
    );
    api.workspaces[_team] = _adasWorkspace;
    store = NotesStore(api: api, currentUserId: 'u-me');
    settings = SettingsStore(api: api);
  });

  tearDown(() {
    store.dispose();
    settings.dispose();
  });

  Future<void> openWorkspace(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await store.load();
    await settings.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(home: WorkspaceSettingsScreen(workspaceId: id)),
      ),
    );
    await tester.pumpAndSettle();
  }

  SwitchListTile switchFor(WidgetTester tester, String title) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

  testWidgets('the owner switches a feature off for everyone', (tester) async {
    await openWorkspace(tester, 'w-default');

    await tester.tap(find.text('Automatic labeling'));
    await tester.pumpAndSettle();

    final ai = store.workspaceById('w-default')!.ai;
    expect(ai.switches.labeling, isFalse);
    expect(ai.allows(AiFeature.chat), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    expect(api.log, contains('updateWorkspaceAi:w-default'));
    expect(api.workspaces['w-default']!.ai.switches.labeling, isFalse);
  });

  testWidgets('turning AI off parks the features without forgetting them', (
    tester,
  ) async {
    await openWorkspace(tester, 'w-default');

    await tester.tap(find.text('AI in this workspace'));
    await tester.pumpAndSettle();

    for (final title in [
      'Automatic labeling',
      'Notes chat',
      'AI note editing',
    ]) {
      final row = switchFor(tester, title);
      expect(row.onChanged, isNull, reason: title);
      expect(row.value, isTrue, reason: title);
    }
    // Assistant access is about tokens, not the provider.
    expect(switchFor(tester, 'Assistant access (MCP)').onChanged, isNotNull);
    expect(
      store.workspaceById('w-default')!.ai.allows(AiFeature.writing),
      isFalse,
    );
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets("a member reads the owner's choices", (tester) async {
    await openWorkspace(tester, _team);

    expect(find.text("Runs on Ada's AI provider"), findsOneWidget);
    expect(find.text('Only Ada can change these.'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ListView), matching: find.byType(Switch)),
      findsNothing,
    );
    final labeling = find.ancestor(
      of: find.text('Automatic labeling'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: labeling, matching: find.text('Off')),
      findsOneWidget,
    );
    final chat = find.ancestor(
      of: find.text('Notes chat'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: chat, matching: find.text('On')),
      findsOneWidget,
    );
  });

  testWidgets('a feature the server pins stays locked', (tester) async {
    api.managedSettings = {
      'llm_chat': const ManagedSetting(secret: false, value: false),
    };
    await openWorkspace(tester, 'w-default');

    expect(switchFor(tester, 'Notes chat').onChanged, isNull);
    expect(switchFor(tester, 'Automatic labeling').onChanged, isNotNull);
    expect(find.text('Managed by the server'), findsOneWidget);
  });

  testWidgets('an owner without a provider is sent to set one up', (
    tester,
  ) async {
    api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
      ai: const WorkspaceAi(),
    );
    await openWorkspace(tester, 'w-default');

    expect(find.text('Needs your AI provider'), findsOneWidget);
    await tester.tap(find.text('Set up your AI provider'));
    await tester.pumpAndSettle();
    expect(find.text('AI & search'), findsOneWidget);
    expect(find.text('AI provider'), findsOneWidget);
  });

  testWidgets('the chat button follows the open workspace', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    api.workspaces[_team] = _adasWorkspace.copyWith(
      ai: const WorkspaceAi(
        providerReady: true,
        switches: AiSwitches(chat: false),
      ),
    );
    await store.load();
    await settings.load();
    await tester.pumpWidget(homeApp(store, settings: settings));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Chat with your notes'), findsOneWidget);

    store.setActiveWorkspace(_team);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Chat with your notes'), findsNothing);
  });

  test('a note from a workspace this user is not in gets no AI', () async {
    await store.load();
    expect(store.aiIn('w-default').allows(AiFeature.writing), isTrue);
    expect(store.aiIn('w-elsewhere').allows(AiFeature.writing), isFalse);
    expect(store.aiIn(_team).rewriteTasks, isEmpty);
  });

  test('workspace AI survives the JSON round trip', () {
    const ai = WorkspaceAi(
      providerReady: true,
      switches: AiSwitches(chat: false, assistantAccess: false),
      rewriteTasks: [NoteRewriteTask(id: 'f', name: 'Friendly', prompt: '')],
    );
    final json = const Workspace(id: 'w', name: 'W', ai: ai).toJson();
    final back = Workspace.fromJson(json).ai;
    expect(back.switches, ai.switches);
    expect(back.providerReady, isTrue);
    expect(back.rewriteTasks.single.name, 'Friendly');
    // An older server sends no `ai`: everything on, nothing to run it.
    final legacy = Workspace.fromJson({'id': 'w', 'name': 'W'}).ai;
    expect(legacy.switches, const AiSwitches());
    expect(legacy.allows(AiFeature.chat), isFalse);
  });
}
