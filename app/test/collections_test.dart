import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skippy/models/collection.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/saved_view.dart';
import 'package:skippy/state/local_cache.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/theme.dart';
import 'package:skippy/widgets/collection_settings.dart';
import 'package:skippy/widgets/duplicate_workspace_dialog.dart';
import 'package:skippy/widgets/board/board_view.dart';
import 'fake_api.dart';
import 'widget_test.dart' show homeApp;

const reading = NoteCollection(
  id: 'reading',
  workspaceId: 'w-default',
  name: 'Reading',
  icon: 'book',
  color: '#00897B',
);
const projects = NoteCollection(
  id: 'projects',
  workspaceId: 'w-default',
  name: 'Projects',
  layout: 'board',
  icon: 'work',
);

class PlacementApi extends FakeApi {
  final placements = <String?>[];
  @override
  Future<void> createNote(Note note, {bool preserveTimestamps = false}) {
    if (failWith == null) {
      expect(
        workspaces[note.workspaceId]!.collections.any(
          (c) => c.id == note.collectionId,
        ),
        isTrue,
      );
      placements.add(note.collectionId);
    }
    return super.createNote(note, preserveTimestamps: preserveTimestamps);
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('COLLECTION_SCREENSHOTS')) {
    return;
  }
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '/tmp/skippy-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const root = String.fromEnvironment('FONT_ROOT');
    if (root.isEmpty) {
      return;
    }
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'Ahem': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          File(
            '$root/${entry.value}',
          ).readAsBytes().then((v) => ByteData.sublistView(v)),
        );
      await loader.load();
    }
  });
  test(
    'collection writes and note placement survive offline restart in order',
    () async {
      final api = FakeApi();
      final cache = MemoryLocalCache();
      var store = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
      await store.load();
      api.failWith = TimeoutException('offline');
      store.saveCollection(reading);
      store.selectCollection(reading.id);
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: 'A book');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(store.noteById(note.id)!.collectionId, reading.id);
      store.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      store = NotesStore(api: api, cache: cache, currentUserId: 'u-me');
      await store.load();
      expect(store.activeCollection?.id, reading.id);
      expect(store.noteById(note.id)?.title, 'A book');
      api.failWith = null;
      api.log.clear();
      await store.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        api.workspaces['w-default']!.collections.any((c) => c.id == reading.id),
        isTrue,
      );
      expect(api.notes[note.id]?.collectionId, reading.id);
      expect(
        api.log.indexOf('putCollection:reading'),
        lessThan(api.log.indexOf('createNote:${note.id}')),
      );
      store.dispose();
    },
  );

  test(
    'filters stay inside the active collection and moves clear columns',
    () async {
      final api = FakeApi();
      api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
        collections: [reading, projects],
      );
      for (final c in [reading, projects]) {
        api.notes[c.id] = Note(
          id: c.id,
          workspaceId: c.workspaceId,
          collectionId: c.id,
          title: c.name,
          labelIds: {'l'},
          stageId: 'todo',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
      }
      api.labels['l'] = const Label(
        id: 'l',
        workspaceId: 'w-default',
        name: 'Important',
      );
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();
      store.selectCollection(reading.id);
      expect(
        store
            .notesFor(const ViewSelection(NoteView.label, 'l'), '')
            .others
            .map((n) => n.id),
        ['reading'],
      );
      store.moveToCollection('reading', 'projects');
      expect(store.noteById('reading')!.stageId, isNull);
      expect(store.noteById('reading')!.labelIds, {'l'});
      expect(store.notesFor(ViewSelection.notes, '').isEmpty, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      store.dispose();
    },
  );

  test(
    'an offline note is created before moving into a later collection',
    () async {
      final api = PlacementApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();
      final initial = store.activeCollection!.id;
      api.failWith = TimeoutException('offline');
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: 'Keep me');
      store.saveCollection(reading);
      store.moveToCollection(note.id, reading.id);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      api.failWith = null;
      await store.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(api.placements, [initial]);
      expect(api.notes[note.id]?.collectionId, reading.id);
      expect(api.notes[note.id]?.title, 'Keep me');
      store.dispose();
    },
  );

  test(
    'composing after the last collection is deleted creates a fresh base',
    () async {
      final api = PlacementApi();
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();
      final oldId = store.activeCollection!.id;
      store.deleteCollection(oldId);
      final note = store.createDraft();
      store.updateNoteContent(note.id, title: 'Shared text');
      expect(store.activeCollection!.name, 'General');
      expect(note.collectionId, isNot(oldId));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(api.notes[note.id]?.collectionId, note.collectionId);
      store.dispose();
    },
  );

  testWidgets('sidebar keeps collection filters and settings together', (
    tester,
  ) async {
    final api = FakeApi();
    api.labels['l'] = const Label(
      id: 'l',
      workspaceId: 'w-default',
      name: 'Important',
    );
    final store = NotesStore(api: api, currentUserId: 'u-me');
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Important'));
    await tester.pumpAndSettle();
    expect(find.text('Important'), findsOneWidget);
    expect(find.byTooltip('Collection settings'), findsOneWidget);
    store.dispose();
    await tester.pump(const Duration(milliseconds: 700));
  });

  for (final (size, brightness) in [
    (const Size(390, 844), Brightness.light),
    (const Size(1280, 900), Brightness.light),
    (const Size(390, 844), Brightness.dark),
    (const Size(1280, 900), Brightness.dark),
  ]) {
    testWidgets(
      'collections render and retain layout at ${size.width} ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final api = FakeApi();
        api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
          collections: [reading, projects],
        );
        api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
          savedViews: const [
            SavedView(id: 'pinned', name: 'Pinned', query: 'is:pinned'),
          ],
        );
        api.labels['ideas'] = const Label(
          id: 'ideas',
          workspaceId: 'w-default',
          name: 'Ideas',
          icon: 'idea',
          color: '#00897B',
        );
        api.labels['to-read'] = const Label(
          id: 'to-read',
          workspaceId: 'w-default',
          name: 'To read',
          icon: 'bookmark',
          color: '#9334E6',
        );
        final now = DateTime(2026, 9, 11);
        api.notes['n'] = Note(
          id: 'n',
          workspaceId: 'w-default',
          collectionId: reading.id,
          title: 'Books for this autumn',
          content:
              'The Left Hand of Darkness\nA Field Guide to Getting Lost\nThe Creative Act',
          pinned: true,
          color: 'yellow',
          labelIds: {'to-read'},
          createdAt: now,
          updatedAt: now,
        );
        api.notes['walks'] = Note(
          id: 'walks',
          workspaceId: 'w-default',
          collectionId: reading.id,
          title: 'A little room for ideas',
          content:
              'Read slowly. Leave a note in the margin. Come back to the passages that stay with you.',
          labelIds: {'ideas'},
          createdAt: now,
          updatedAt: now,
        );
        api.notes['weekend'] = Note(
          id: 'weekend',
          workspaceId: 'w-default',
          collectionId: reading.id,
          title: 'Saturday morning',
          kind: NoteKind.checklist,
          items: const [
            ChecklistItem(id: 'a', text: 'Coffee and a few chapters'),
            ChecklistItem(id: 'b', text: 'Visit the bookshop'),
            ChecklistItem(id: 'c', text: 'Walk by the lake'),
          ],
          createdAt: now,
          updatedAt: now,
        );
        api.notes['quote'] = Note(
          id: 'quote',
          workspaceId: 'w-default',
          collectionId: reading.id,
          title: 'Notes from the book club',
          content:
              'What changed your mind?\n\nBring one passage to our next conversation.',
          labelIds: {'ideas'},
          createdAt: now,
          updatedAt: now,
        );
        api.stages['todo'] = const Stage(
          id: 'todo',
          workspaceId: 'w-default',
          collectionId: 'projects',
          name: 'To do',
          position: 0,
        );
        api.stages['doing'] = const Stage(
          id: 'doing',
          workspaceId: 'w-default',
          collectionId: 'projects',
          name: 'In progress',
          position: 1,
          color: '#00897B',
        );
        api.notes['project'] = Note(
          id: 'project',
          workspaceId: 'w-default',
          collectionId: 'projects',
          title: 'Plan the reading corner',
          content:
              'A comfortable chair, a warm lamp, and space for the next good book.',
          stageId: 'doing',
          createdAt: now,
          updatedAt: now,
        );
        final store = NotesStore(api: api, currentUserId: 'u-me');
        await store.load();
        store.selectCollection(reading.id);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: homeApp(store, brightness: brightness),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Books for this autumn'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final suffix = '${brightness.name}-${size.width.toInt()}';
        await _capture(tester, key, 'collections-$suffix');
        if (size.width < 600) {
          await tester.tap(find.byIcon(Icons.menu));
          await tester.pumpAndSettle();
          await _capture(tester, key, 'collection-sidebar-$suffix');
        }
        await tester.tap(find.byTooltip('Collection settings'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _capture(tester, key, 'collection-settings-$suffix');
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        unawaited(
          DuplicateWorkspaceDialog.show(
            tester.element(find.byType(Scaffold).first),
            store.activeWorkspace!,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Structure and notes'));
        await tester.pumpAndSettle();
        expect(find.text('Copy reminders'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, key, 'duplicate-workspace-$suffix');
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        store.selectCollection(projects.id);
        await tester.pumpAndSettle();
        expect(find.byType(BoardView), findsOneWidget);
        expect(find.text('Books for this autumn'), findsNothing);
        expect(tester.takeException(), isNull);
        await _capture(tester, key, 'collection-board-$suffix');
        store.dispose();
        await tester.pump(const Duration(milliseconds: 700));
      },
    );
  }

  testWidgets('phone drawer closes before creating a collection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = NotesStore(api: FakeApi(), currentUserId: 'u-me');
    await store.load();
    await tester.pumpWidget(homeApp(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New collection'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(find.widgetWithText(AppBar, 'New collection'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Recipes');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(store.activeCollection?.name, 'Recipes');
    expect(find.byType(Drawer), findsNothing);
    store.dispose();
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets(
    'deleting a collection names its notes and restoring asks for a destination',
    (tester) async {
      final api = FakeApi();
      api.workspaces['w-default'] = api.workspaces['w-default']!.copyWith(
        collections: [reading, projects],
      );
      api.notes['n'] = Note(
        id: 'n',
        workspaceId: 'w-default',
        collectionId: reading.id,
        title: 'Book',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final store = NotesStore(api: api, currentUserId: 'u-me');
      await store.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: store),
            ChangeNotifierProvider(create: (_) => SettingsStore(api: api)),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () =>
                          CollectionSettings.show(context, collection: reading),
                      child: const Text('Settings'),
                    ),
                    TextButton(
                      onPressed: () => CollectionPicker.restore(context, 'n'),
                      child: const Text('Restore'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete collection'));
      await tester.tap(find.text('Delete collection'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Reading?'), findsOneWidget);
      expect(find.textContaining('1 note will'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete collection'));
      await tester.pumpAndSettle();
      expect(store.noteById('n')!.trashed, isTrue);
      expect(store.collections.any((c) => c.id == reading.id), isFalse);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Projects'));
      await tester.pumpAndSettle();
      expect(store.noteById('n')!.trashed, isFalse);
      expect(store.noteById('n')!.collectionId, projects.id);
      store.dispose();
      await tester.pump(const Duration(milliseconds: 700));
    },
  );
}
