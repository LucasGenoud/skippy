import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/api_token.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/settings/ai_access_section.dart';

import 'checklist_test.dart' show harness;
import 'fake_api.dart';

void main() {
  late FakeApi api;
  late NotesStore store;

  setUp(() {
    api = FakeApi();
    store = NotesStore(api: api, currentUserId: 'u-me');
  });
  tearDown(() => store.dispose());

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(
      harness(store, ListView(children: const [AiAccessSection()])),
    );
    await tester.pumpAndSettle();
  }

  test('the connection details point at this server', () {
    expect(mcpUrl('https://notes.example/'), 'https://notes.example/api/mcp');
    expect(
      claudeCodeCommand('https://notes.example', 'skp_x'),
      'claude mcp add --transport http skippy https://notes.example/api/mcp '
      '--header "Authorization: Bearer skp_x"',
    );
  });

  testWidgets('a new token is shown once, then listed without its secret', (
    tester,
  ) async {
    await pumpSection(tester);

    await tester.tap(find.byKey(const Key('new-api-token')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('api-token-name')), 'Claude');
    await tester.tap(find.text(TokenScope.write.label));
    await tester.pump();
    await tester.tap(find.byKey(const Key('create-api-token')));
    await tester.pumpAndSettle();

    expect(api.apiTokens.values.single.scope, TokenScope.write);
    expect(find.textContaining('skp_secret_api-0'), findsWidgets);
    await tester.tap(find.byKey(const Key('api-token-done')));
    await tester.pumpAndSettle();

    expect(find.text('Claude'), findsOneWidget);
    expect(find.textContaining('skp_secret'), findsNothing);
  });

  testWidgets('revoking a token removes it', (tester) async {
    await api.createApiToken('Old agent', TokenScope.read);
    await pumpSection(tester);

    await tester.tap(find.byTooltip('Revoke token'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();

    expect(api.apiTokens, isEmpty);
    expect(find.text('Old agent'), findsNothing);
  });
}
