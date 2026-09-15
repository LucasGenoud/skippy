import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/masonry.dart';

import 'notes_store_test.dart' show serverNote;

void main() {
  testWidgets('cards are visible immediately on opening and switching views', (
    tester,
  ) async {
    for (final view in ['notes', 'archive']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedMasonry(
              key: ValueKey(view),
              notes: [serverNote('n1', title: 'Visible card')],
              columns: 1,
              itemBuilder: (_, note) => Text(note.title),
            ),
          ),
        ),
      );

      expect(find.text('Visible card'), findsOneWidget);
      expect(
        tester
            .widgetList<Opacity>(
              find.ancestor(
                of: find.text('Visible card'),
                matching: find.byType(Opacity),
              ),
            )
            .every((opacity) => opacity.opacity == 1),
        isTrue,
        reason: 'cards must not wait for measurement or an entrance animation',
      );
    }
    await tester.pumpAndSettle();
  });
}
