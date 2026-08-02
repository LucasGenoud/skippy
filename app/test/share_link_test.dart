import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/share_link.dart';
import 'package:skippy/screens/public_share_screen.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/public_route.dart';
import 'package:skippy/util/snack.dart';
import 'package:skippy/widgets/public_link_dialog.dart';
import 'package:skippy/widgets/share_dialog.dart';

import 'fake_api.dart';

void main() {
  group('public share routing', () {
    test('reads the token out of a /s/ path and refuses anything else', () {
      expect(publicShareToken('/s/abc123'), 'abc123');
      expect(publicShareToken('/s/abc123/'), 'abc123');
      expect(publicShareToken('/s/deadBEEF42?utm=1'), 'deadBEEF42');
      // A deployment served under a sub-path still resolves.
      expect(publicShareToken('/notes/s/abc123'), 'abc123');

      expect(publicShareToken('/'), isNull);
      expect(publicShareToken('/s/'), isNull);
      // Only the hex the server mints, so a stray path never sends someone to
      // a share page that could not have resolved.
      expect(publicShareToken('/s/not-a-token'), isNull);
      expect(publicShareToken('/settings'), isNull);
    });

    test('builds the URL to hand out from the server origin', () {
      final link = ShareLink(
        token: 'abc',
        target: ShareTarget.note,
        title: 'Focaccia',
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        publicShareUrl('https://notes.example', link),
        'https://notes.example/s/abc',
      );
      // A trailing slash on the configured base must not double up.
      expect(
        publicShareUrl('https://notes.example/', link),
        'https://notes.example/s/abc',
      );
    });
  });

  group('PublicLinkDialog', () {
    late FakeApi api;

    setUp(() => api = FakeApi());

    Widget host(FakeApi api) => MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => PublicLinkDialog.show(
              context,
              target: PublicLinkTarget.note('n1', 'Focaccia'),
              api: api,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('publishes only when asked, then copies and revokes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(api));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Opening the dialog must not put anything on the internet.
      expect(api.shareLinks, isEmpty);
      expect(find.text('Create link'), findsOneWidget);

      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(api.shareLinks.length, 1);
      final link = api.shareLinks.values.single;
      expect(link.target, ShareTarget.note);
      expect(link.noteId, 'n1');
      expect(link.expiresAt, isNull);
      // The URL is shown so it can be read or copied by hand.
      expect(find.text(publicShareUrl(api.baseUrl, link)), findsOneWidget);

      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
      await tester.pumpAndSettle();
      expect(api.shareLinks, isEmpty);
      expect(find.text('Create link'), findsOneWidget);
    });

    testWidgets('shows the link that already exists instead of a second one', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final existing = await api.createShareLink(
        target: ShareTarget.note,
        noteId: 'n1',
      );

      await tester.pumpWidget(host(api));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Create link'), findsNothing);
      expect(find.text(publicShareUrl(api.baseUrl, existing)), findsOneWidget);
      expect(find.text('Works until you revoke it'), findsOneWidget);
    });

    testWidgets('an expiry choice rides along to the server', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(api));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Until I revoke it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7 days').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();

      final expires = api.shareLinks.values.single.expiresAt;
      expect(expires, isNotNull);
      expect(expires!.difference(DateTime.now()).inHours, closeTo(24 * 7, 2));
    });
  });

  group('PublicShareScreen', () {
    late FakeApi api;
    setUp(() => api = FakeApi());

    Widget host(FakeApi api, String token) => MaterialApp(
      home: PublicShareScreen(token: token, api: api),
    );

    Note note(String id, {String title = '', String content = ''}) => Note(
      id: id,
      title: title,
      content: content,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    testWidgets('renders a shared note read-only, naming who shared it', (
      tester,
    ) async {
      api.publicShares['tok'] = PublicShare(
        target: ShareTarget.note,
        title: 'Focaccia',
        sharedBy: 'Ada',
        notes: [note('n1', title: 'Focaccia', content: 'flour, water, salt')],
      );

      await tester.pumpWidget(host(api, 'tok'));
      await tester.pumpAndSettle();

      expect(find.text('Focaccia'), findsWidgets);
      expect(find.text('flour, water, salt'), findsOneWidget);
      expect(find.text('Shared by Ada'), findsOneWidget);
      expect(find.text('Read only'), findsOneWidget);
    });

    testWidgets('a revoked or expired link says so without saying which', (
      tester,
    ) async {
      await tester.pumpWidget(host(api, 'gone'));
      await tester.pumpAndSettle();

      expect(find.text('This link is not available'), findsOneWidget);
      // No note content, and nothing that would confirm the token was ever
      // real.
      expect(find.text('Read only'), findsNothing);
    });

    testWidgets('a shared board draws its columns', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      api.publicShares['tok'] = PublicShare(
        target: ShareTarget.board,
        title: 'Team',
        sharedBy: 'Ada',
        notes: [
          note('n1', title: 'Ship it').copyWith(stageId: 's1'),
          note('n2', title: 'Someday'),
        ],
        stages: const [Stage(id: 's1', name: 'Doing')],
      );

      await tester.pumpWidget(host(api, 'tok'));
      await tester.pumpAndSettle();

      expect(find.text('Doing'), findsOneWidget);
      expect(find.text('Unassigned'), findsOneWidget);
      expect(find.text('Ship it'), findsOneWidget);
      expect(find.text('Someday'), findsOneWidget);
    });
  });

  test('the fake mirrors the server: publishing twice is one link', () async {
    final api = FakeApi();
    final first = await api.createShareLink(
      target: ShareTarget.note,
      noteId: 'n1',
    );
    final second = await api.createShareLink(
      target: ShareTarget.note,
      noteId: 'n1',
    );
    expect(first.token, second.token);
    expect(api.shareLinks.length, 1);
  });

  group('note share dialog', () {
    Future<void> pumpDialog(WidgetTester tester, String ownerId) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final api = FakeApi();
      api.notes['n1'] = Note(
        id: 'n1',
        title: 'Focaccia',
        owner: UserRef(id: ownerId, name: ownerId),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final store = NotesStore(api: api, currentUserId: 'u-me');
      addTearDown(store.dispose);
      await store.load();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: store,
          child: MaterialApp(
            scaffoldMessengerKey: scaffoldMessengerKey,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => ShareDialog.show(context, 'n1'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers the owner a public link beside the roster', (
      tester,
    ) async {
      await pumpDialog(tester, 'u-me');
      expect(find.text('Public link'), findsOneWidget);
    });

    testWidgets('does not offer one to a collaborator', (tester) async {
      // Publishing is the owner's call, and the server refuses it anyway, so
      // the option is not shown to someone who could not use it.
      await pumpDialog(tester, 'someone-else');
      expect(find.text('Public link'), findsNothing);
    });
  });
}
