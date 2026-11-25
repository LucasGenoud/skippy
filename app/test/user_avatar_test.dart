import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/state/avatar_cache.dart';
import 'package:skippy/widgets/user_avatar.dart';

import 'fake_api.dart';

void main() {
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

  Widget harness(AvatarCache cache, Widget child) => MaterialApp(
    home: Scaffold(
      body: Provider<AvatarCache>.value(value: cache, child: child),
    ),
  );

  testWidgets('shows the initial when there is no picture', (tester) async {
    final cache = AvatarCache(api: FakeApi());
    await tester.pumpWidget(
      harness(
        cache,
        const UserAvatar(userId: 'u1', version: null, fallback: Text('A')),
      ),
    );
    expect(find.text('A'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('shows the picture, and keeps it across rebuilds', (
    tester,
  ) async {
    final api = FakeApi()..avatars['u1'] = png;
    final cache = AvatarCache(api: api);
    Widget build(String label) => harness(
      cache,
      Column(
        children: [
          Text(label),
          // ignore: prefer_const_constructors
          UserAvatar(userId: 'u1', version: 2, fallback: Text('A')),
        ],
      ),
    );
    await tester.pumpWidget(build('one'));
    await tester.pump();
    final first = tester.widget<Image>(find.byType(Image)).image;

    await tester.pumpWidget(build('two'));
    expect(tester.widget<Image>(find.byType(Image)).image, same(first));
  });

  testWidgets('a user the account may not see keeps the initial', (
    tester,
  ) async {
    final cache = AvatarCache(api: FakeApi());
    await tester.pumpWidget(
      harness(
        cache,
        const UserAvatar(userId: 'u9', version: 4, fallback: Text('Z')),
      ),
    );
    await tester.pump();
    expect(find.text('Z'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
