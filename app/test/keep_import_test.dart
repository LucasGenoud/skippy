import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/collection.dart';
import 'package:skippy/models/workspace.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/util/keep_import.dart';
import 'package:skippy/widgets/settings/export_section.dart';

import 'fake_api.dart';

Uint8List takeout(Map<String, Object> files) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    final bytes = value is String
        ? utf8.encode(value)
        : value is Map
        ? utf8.encode(jsonEncode(value))
        : value as List<int>;
    archive.addFile(ArchiveFile(key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _usec2024 = 1704067200000000; // 2024-01-01T00:00:00Z
const _usec2025 = 1735689600000000; // 2025-01-01T00:00:00Z

void main() {
  test('reads text notes, checklists, labels and flags', () {
    final bytes = takeout({
      'Takeout/Keep/Shopping.json': {
        'title': 'Shopping',
        'color': 'TEAL',
        'isPinned': true,
        'isArchived': false,
        'isTrashed': false,
        'listContent': [
          {'text': 'Milk', 'isChecked': true},
          {'text': 'Eggs', 'isChecked': false},
        ],
        'labels': [
          {'name': 'Home'},
        ],
        'createdTimestampUsec': _usec2024,
        'userEditedTimestampUsec': _usec2025,
      },
      'Takeout/Keep/Idea.json': {
        'title': '',
        'color': 'PURPLE',
        'isPinned': false,
        'isArchived': true,
        'isTrashed': false,
        'textContent': 'Build a boat',
        'annotations': [
          {'source': 'WEBLINK', 'url': 'https://boats.example'},
        ],
        'userEditedTimestampUsec': _usec2024,
      },
      'Takeout/Keep/Shopping.html': '<html></html>',
      'Takeout/Keep/Labels.txt': 'Home\n',
    });

    final notes = parseKeepArchive(bytes).notes;
    final shopping = notes.singleWhere((n) => n.title == 'Shopping');
    final idea = notes.singleWhere((n) => n.title.isEmpty);

    expect(shopping.kind, NoteKind.checklist);
    expect(shopping.items.map((i) => (i.text, i.done)), [
      ('Milk', true),
      ('Eggs', false),
    ]);
    expect(shopping.color, 'teal');
    expect(shopping.pinned, isTrue);
    expect(shopping.labels, ['Home']);
    expect(shopping.createdAt, DateTime.utc(2024));
    expect(shopping.updatedAt, DateTime.utc(2025));

    expect(idea.kind, NoteKind.text);
    expect(idea.content, 'Build a boat\n\nhttps://boats.example');
    expect(idea.color, 'blue');
    expect(idea.archived, isTrue);
    expect(idea.createdAt, DateTime.utc(2024));
  });

  test('attaches files, tolerating the extension Keep gets wrong', () {
    final bytes = takeout({
      'Takeout/Keep/Photo.json': {
        'title': 'Photo',
        'textContent': '',
        'isTrashed': false,
        'attachments': [
          {'filePath': 'abc.jpeg', 'mimetype': 'image/jpeg'},
          {'filePath': 'gone.png', 'mimetype': 'image/png'},
        ],
        'userEditedTimestampUsec': _usec2024,
      },
      'Takeout/Keep/abc.jpg': [1, 2, 3],
    });

    final archive = parseKeepArchive(bytes);
    final attachment = archive.notes.single.attachments.single;

    expect(attachment.filename, 'abc.jpg');
    expect(attachment.mime, 'image/jpeg');
    expect(attachment.bytes, [1, 2, 3]);
    expect(archive.missingFiles, 1);
  });

  test('keeps trashed notes marked so the import can skip them', () {
    final bytes = takeout({
      'Takeout/Keep/Old.json': {
        'title': 'Old',
        'textContent': 'x',
        'isTrashed': true,
        'userEditedTimestampUsec': _usec2024,
      },
    });

    expect(parseKeepArchive(bytes).notes.single.trashed, isTrue);
  });

  test('rejects an archive with no Keep notes in it', () {
    expect(
      () => parseKeepArchive(takeout({'Takeout/Drive/a.json': '{}'})),
      throwsFormatException,
    );
    expect(
      () => parseKeepArchive(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  group('importKeep', () {
    KeepNote keep(
      String title, {
      bool trashed = false,
      List<String> labels = const [],
      int year = 2024,
      List<KeepAttachment> attachments = const [],
    }) => KeepNote(
      title: title,
      kind: NoteKind.text,
      content: 'body',
      items: const [],
      color: 'default',
      pinned: false,
      archived: false,
      trashed: trashed,
      createdAt: DateTime.utc(year),
      updatedAt: DateTime.utc(year),
      labels: labels,
      attachments: attachments,
    );

    test('adds notes beside existing ones, sharing labels by name', () async {
      final api = FakeApi()
        ..notes['mine'] = Note(
          id: 'mine',
          workspaceId: 'w-default',
          title: 'Already here',
          createdAt: DateTime.utc(2023),
          updatedAt: DateTime.utc(2023),
        )
        ..labels['l-home'] = const Label(
          id: 'l-home',
          name: 'Home',
          workspaceId: 'w-default',
        );
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();

      final result = await store.importKeep(
        KeepArchive(
          notes: [
            keep('Old', labels: ['home'], year: 2020),
            keep(
              'New',
              labels: ['Work'],
              year: 2025,
              attachments: [
                KeepAttachment(
                  filename: 'a.png',
                  mime: 'image/png',
                  bytes: Uint8List.fromList([1]),
                ),
              ],
            ),
            keep('Binned', trashed: true),
          ],
          missingFiles: 0,
        ),
        workspaceId: 'w-default',
        collectionId: 'w-default-general',
      );
      store.dispose();

      expect(result.notes, 2);
      expect(result.attachments, 1);
      expect(result.labels, 1);
      expect(api.notes['mine']!.title, 'Already here');
      final byTitle = {for (final n in api.notes.values) n.title: n};
      expect(byTitle.keys, containsAll(['Old', 'New']));
      expect(byTitle, isNot(contains('Binned')));
      expect(byTitle['Old']!.labelIds, {'l-home'});
      expect(byTitle['Old']!.collectionId, 'w-default-general');
      expect(byTitle['Old']!.updatedAt, DateTime.utc(2020));
      final work = api.labels.values.singleWhere((l) => l.name == 'Work');
      expect(byTitle['New']!.labelIds, {work.id});
      expect(byTitle['New']!.attachments.single.filename, 'a.png');
      // The most recently edited note lands first.
      expect(byTitle['New']!.position, lessThan(byTitle['Old']!.position));
    });

    test('brings trashed notes along when asked', () async {
      final api = FakeApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();

      await store.importKeep(
        KeepArchive(notes: [keep('Binned', trashed: true)], missingFiles: 0),
        workspaceId: 'w-default',
        collectionId: 'w-default-general',
        trash: KeepTrash.include,
      );
      store.dispose();

      expect(api.notes.values.single.trashed, isTrue);
    });
  });

  testWidgets('the dialog files the import where it was asked to', (
    tester,
  ) async {
    const workspaces = [
      Workspace(
        id: 'w1',
        name: 'Home',
        collections: [
          NoteCollection(id: 'c1', workspaceId: 'w1', name: 'General'),
        ],
      ),
      Workspace(
        id: 'w2',
        name: 'Work',
        collections: [
          NoteCollection(id: 'c2', workspaceId: 'w2', name: 'Inbox'),
        ],
      ),
    ];
    final archive = KeepArchive(
      notes: [
        for (final trashed in [false, true])
          KeepNote(
            title: 'n',
            kind: NoteKind.text,
            content: '',
            items: const [],
            color: 'default',
            pinned: false,
            archived: false,
            trashed: trashed,
            createdAt: DateTime.utc(2024),
            updatedAt: DateTime.utc(2024),
            labels: const [],
            attachments: const [],
          ),
      ],
      missingFiles: 0,
    );
    KeepImportChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => choice = await showDialog(
              context: context,
              builder: (_) => KeepImportDialog(
                archive: archive,
                workspaces: workspaces,
                initialWorkspaceId: 'w2',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 note and 0 files'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.tap(find.byKey(const Key('keep-import-confirm')));
    await tester.pumpAndSettle();

    expect(choice?.workspaceId, 'w2');
    expect(choice?.collectionId, 'c2');
    expect(choice?.trash, KeepTrash.include);
  });
}
