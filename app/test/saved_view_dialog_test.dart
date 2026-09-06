import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/widgets/saved_view_dialog.dart';
import 'fake_api.dart';

void main() {
  testWidgets('an open smart view editor handles a deleted view', (
    tester,
  ) async {
    final store = NotesStore(api: FakeApi(), currentUserId: 'u-me');
    addTearDown(store.dispose);
    await store.load();
    final view = store.addSavedView(name: 'Pinned', query: 'is:pinned');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(home: SavedViewDialog(savedViewId: view.id)),
      ),
    );
    await tester.pumpAndSettle();
    store.removeSavedView(view.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('This smart view is no longer available'), findsOneWidget);
  });
}
