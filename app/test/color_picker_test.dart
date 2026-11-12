import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/color_picker.dart';

import 'fake_api.dart';

void main() {
  testWidgets('motifs share the pattern strip and pick like any pattern', (
    tester,
  ) async {
    NotePattern? picked;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsStore(api: FakeApi()),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ColorPickerSheet(
                selected: 'default',
                onSelect: (_) {},
                onSelectPattern: (pattern) => picked = pattern,
              ),
            ),
          ),
        ),
      ),
    );

    // One strip holds textures and motifs alike.
    expect(find.text('Pattern'), findsOneWidget);
    expect(find.text('MOTIF'), findsNothing);
    for (final pattern in NotePattern.values) {
      expect(find.byKey(ValueKey('pattern-${pattern.wire}')), findsOneWidget);
    }

    final airplanes = find.byKey(const ValueKey('pattern-airplanes'));
    await tester.tap(airplanes);
    expect(picked, NotePattern.airplanes);
  });

  test('motif wire values round-trip and stay distinct', () {
    final wires = {for (final pattern in NotePattern.values) pattern.wire};
    expect(wires, hasLength(NotePattern.values.length));
    for (final pattern in NotePattern.values) {
      expect(NotePattern.fromWire(pattern.wire), pattern);
    }
  });
}
