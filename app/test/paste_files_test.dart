import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/dropped_file.dart';
import 'package:skippy/widgets/paste_files.dart';

KeyboardInsertedContent _inserted({
  String mime = 'image/png',
  Uint8List? data,
}) => KeyboardInsertedContent(
  mimeType: mime,
  uri: 'content://media/external/images/1',
  data: data ?? Uint8List.fromList([137, 80, 78, 71]),
);

void main() {
  group('pastedContentFile', () {
    test('builds an uploadable file with a stamped name', () {
      final file = pastedContentFile(
        _inserted(),
        at: DateTime(2026, 8, 5, 14, 3, 9),
      )!;
      expect(file.mime, 'image/png');
      expect(file.name, 'pasted-20260805-140309.png');
      expect(file.bytes, [137, 80, 78, 71]);
    });

    test('declines content the platform could not read', () {
      expect(
        pastedContentFile(
          KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://x'),
        ),
        isNull,
      );
      expect(pastedContentFile(_inserted(data: Uint8List(0))), isNull);
    });
  });

  group('PasteFileArea', () {
    /// Pumps an area over a field and hands back the field's insertion
    /// configuration, the hook the Android keyboard commits content through.
    Future<ContentInsertionConfiguration?> pumpArea(
      WidgetTester tester, {
      required bool enabled,
      required List<DroppedFile> received,
    }) async {
      ContentInsertionConfiguration? insertion;
      await tester.pumpWidget(
        MaterialApp(
          home: PasteFileArea(
            enabled: enabled,
            onFiles: (files) async => received.addAll(files),
            child: Builder(
              builder: (context) {
                insertion = PasteFileArea.insertionOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return insertion;
    }

    testWidgets('routes keyboard-inserted images to the note', (tester) async {
      final received = <DroppedFile>[];
      final insertion = await pumpArea(
        tester,
        enabled: true,
        received: received,
      );

      expect(insertion, isNotNull);
      expect(insertion!.allowedMimeTypes, contains('image/png'));
      insertion.onContentInserted(_inserted());

      expect(received.single.mime, 'image/png');
      expect(received.single.bytes, hasLength(4));
    });

    testWidgets('ignores content while disabled', (tester) async {
      final received = <DroppedFile>[];
      final insertion = await pumpArea(
        tester,
        enabled: false,
        received: received,
      );

      insertion!.onContentInserted(_inserted());

      expect(received, isEmpty);
    });

    testWidgets('fields outside an area get no configuration', (tester) async {
      ContentInsertionConfiguration? insertion;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              insertion = PasteFileArea.insertionOf(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(insertion, isNull);
    });
  });
}
