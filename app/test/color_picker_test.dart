import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/widgets/color_picker.dart';

import 'fake_api.dart';

void main() {
  testWidgets('motifs get their own strip and pick like any pattern', (
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

    expect(find.text('PATTERN'), findsOneWidget);
    expect(find.text('MOTIF'), findsOneWidget);
    for (final pattern in NotePattern.values) {
      expect(find.byKey(ValueKey('pattern-${pattern.wire}')), findsOneWidget);
    }

    // Motifs follow the motif heading, textures stay above it.
    final motifTop = tester.getTopLeft(find.text('MOTIF')).dy;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('pattern-grid'))).dy,
      lessThan(motifTop),
    );
    final airplanes = find.byKey(const ValueKey('pattern-airplanes'));
    expect(tester.getTopLeft(airplanes).dy, greaterThan(motifTop));

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
