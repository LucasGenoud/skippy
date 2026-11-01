import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/sync_pill.dart';

import 'fake_api.dart';

void main() {
  testWidgets('says synced once nothing is waiting to be sent', (tester) async {
    final store = NotesStore(api: FakeApi(), currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: SyncPill())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.syncStatus, SyncStatus.synced);
    expect(find.text('Synced'), findsOneWidget);
  });
}
