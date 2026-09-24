import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/notes_store.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote;

class _MeasuringCache extends MemoryLocalCache {
  Duration encodingTime = Duration.zero;
  int bytes = 0;

  @override
  Future<void> write(String key, Map<String, dynamic> doc) async {
    final watch = Stopwatch()..start();
    bytes = utf8.encode(jsonEncode(doc)).length;
    watch.stop();
    encodingTime += watch.elapsed;
    await super.write(key, doc);
  }
}

void main() {
  test('large notebook loads, searches, and persists an edit', () async {
    final api = FakeApi();
    for (var i = 0; i < 5000; i++) {
      api.notes['n$i'] = serverNote(
        'n$i',
        title: i == 2500 ? 'Find this needle' : 'Note $i',
        content: 'A short note with enough text to resemble a real card.',
        position: i.toDouble(),
      );
    }
    final cache = _MeasuringCache();
    final store = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
    final watch = Stopwatch()..start();
    await store.load();
    final load = watch.elapsed;
    watch.reset();
    final found = store.notesFor(ViewSelection.notes, 'needle');
    final search = watch.elapsed;
    expect(found.others.single.id, 'n2500');

    store.updateNoteContent('n2500', content: 'Changed in a large notebook');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(api.notes['n2500']!.content, 'Changed in a large notebook');
    expect(cache.bytes, greaterThan(0));
    // These numbers are diagnostic, not a timing gate: CI hardware varies.
    // ignore: avoid_print
    print(
      '5000 notes: load=$load search=$search cache=${cache.bytes}B '
      'encoding=${cache.encodingTime}',
    );
    store.dispose();
  });
}
