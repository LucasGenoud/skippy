import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_attachment_coordinator.dart';

import 'fake_api.dart';

void main() {
  test(
    'materializes and drains before upload, then replaces local state',
    () async {
      final api = FakeApi();
      final now = DateTime(2026);
      var local = Note(id: 'n1', createdAt: now, updatedAt: now);
      api.notes['n1'] = local;
      final order = <String>[];
      final coordinator = NoteAttachmentCoordinator(
        api: api,
        noteById: (_) => local,
        replace: (note) => local = note,
        ensureMaterialized: (_) async => order.add('materialize'),
        drainQueue: () async => order.add('drain'),
      );

      await coordinator.upload(
        'n1',
        Uint8List.fromList([1, 2, 3]),
        'image/png',
        'image.png',
      );

      expect(order, ['materialize', 'drain']);
      expect(local.attachments.single.filename, 'image.png');
      expect(
        coordinator.removeLocal('n1', local.attachments.single.id),
        isTrue,
      );
      expect(local.attachments, isEmpty);
    },
  );
}
