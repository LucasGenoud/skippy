import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/home_widget_bridge.dart';
import 'package:skippy/state/notes_store.dart';
import 'package:skippy/state/settings_store.dart';
import 'package:skippy/util/home_widgets.dart';
import 'package:skippy/util/widget_payload.dart';

import 'fake_api.dart';
import 'notes_store_test.dart' show serverNote, testStore;

/// Stands in for the shared store the widgets read. Subclassed rather than
/// method-channel-mocked for the same reason [FakeLocalNotifications] is: the
/// seam has to sit above the plugin, which isn't registered under flutter_test.
class FakeHomeWidgets extends HomeWidgets {
  Map<String, dynamic>? notesDoc;
  List<Map<String, dynamic>>? index;
  Map<String, String>? session;
  List<WidgetOp> queued = [];
  List<String> wanted = [];
  int publishCount = 0;
  int clearAllCount = 0;
  int clearOpsCount = 0;

  Map<String, dynamic> get publishedNotes =>
      (notesDoc?['notes'] as Map<String, dynamic>?) ?? {};

  @override
  Future<void> publish({
    required Map<String, dynamic> notesDoc,
    required List<Map<String, dynamic>> index,
  }) async {
    this.notesDoc = notesDoc;
    this.index = index;
    publishCount++;
  }

  @override
  Future<void> setSession({
    required String baseUrl,
    required String token,
  }) async {
    session = {'baseUrl': baseUrl, 'token': token};
  }

  @override
  Future<void> clearSession() async => session = null;

  @override
  Future<List<WidgetOp>> pendingOps() async => queued;

  @override
  Future<void> clearOps() async {
    queued = [];
    clearOpsCount++;
  }

  @override
  Future<List<String>> wantedIds() async => wanted;

  @override
  Future<void> clearAll() async {
    clearAllCount++;
    notesDoc = null;
    index = null;
    session = null;
  }
}

void main() {
  late FakeApi api;
  late NotesStore store;
  late SettingsStore settings;
  late FakeHomeWidgets platform;
  late ApiClient client;
  late HomeWidgetBridge bridge;

  /// Long enough for the bridge's own debounce, which tests shorten.
  Future<void> settleBridge() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  HomeWidgetBridge buildBridge() => HomeWidgetBridge(
    notes: store,
    settings: settings,
    api: client,
    platform: platform,
    debounce: const Duration(milliseconds: 20),
  );

  setUp(() {
    api = FakeApi();
    store = testStore(api);
    settings = SettingsStore(api: api);
    platform = FakeHomeWidgets();
    client = ApiClient()
      ..baseUrl = 'https://notes.example.com'
      ..token = 'tok-123';
  });

  tearDown(() {
    bridge.dispose();
    store.dispose();
    settings.dispose();
  });

  test('publishes the account\'s notes and the picker index', () async {
    api.notes['n1'] = serverNote(
      'n1',
      title: 'Groceries',
      kind: NoteKind.checklist,
      items: const [
        ChecklistItem(id: 'i1', text: 'Milk'),
        ChecklistItem(id: 'i2', text: 'Bread', done: true),
      ],
    );
    await store.load();

    bridge = buildBridge()..start();
    await settleBridge();

    expect(platform.publishedNotes.keys, ['n1']);
    final published = platform.publishedNotes['n1'] as Map<String, dynamic>;
    expect(published['title'], 'Groceries');
    expect(published['pendingCount'], 1);
    // Pending first, so a widget that can only show a couple of rows shows the
    // ones still to do.
    expect((published['items'] as List).first, containsPair('id', 'i1'));
    expect(platform.index?.single, containsPair('title', 'Groceries'));
  });

  test('mirrors the session so a widget can sync a tick on its own', () async {
    await store.load();
    bridge = buildBridge()..start();
    await settleBridge();

    expect(platform.session, {
      'baseUrl': 'https://notes.example.com',
      'token': 'tok-123',
    });
  });

  test('drops the mirrored session when the token goes away', () async {
    await store.load();
    client.token = null;

    bridge = buildBridge()..start();
    await settleBridge();

    expect(platform.session, isNull);
    // Notes still publish: a signed-out widget shows nothing new, but the
    // credential is what must not linger.
    expect(platform.publishCount, greaterThan(0));
  });

  test('applies ticks queued by a widget while the app was closed', () async {
    api.notes['n1'] = serverNote(
      'n1',
      kind: NoteKind.checklist,
      items: const [
        ChecklistItem(id: 'i1', text: 'Milk'),
        ChecklistItem(id: 'i2', text: 'Bread'),
      ],
    );
    await store.load();
    platform.queued = const [
      WidgetOp(noteId: 'n1', itemId: 'i1', done: true),
    ];

    bridge = buildBridge()..start();
    await settleBridge();

    final items = store.noteById('n1')!.items;
    expect(items.firstWhere((i) => i.id == 'i1').done, isTrue);
    expect(items.firstWhere((i) => i.id == 'i2').done, isFalse);
    // The queue is emptied so the tick isn't replayed on the next resume.
    expect(platform.clearOpsCount, 1);
    expect(platform.queued, isEmpty);
  });

  test('a tick the server already took changes nothing', () async {
    api.notes['n1'] = serverNote(
      'n1',
      kind: NoteKind.checklist,
      items: const [ChecklistItem(id: 'i1', text: 'Milk', done: true)],
    );
    await store.load();
    final before = store.noteById('n1')!.updatedAt;
    platform.queued = const [
      WidgetOp(noteId: 'n1', itemId: 'i1', done: true),
    ];

    bridge = buildBridge()..start();
    await settleBridge();

    // Absolute, not a flip: replaying it must not uncheck the item.
    expect(store.noteById('n1')!.items.single.done, isTrue);
    expect(store.noteById('n1')!.updatedAt, before);
  });

  test('republishes when a note changes', () async {
    api.notes['n1'] = serverNote('n1', title: 'First');
    await store.load();
    bridge = buildBridge()..start();
    await settleBridge();
    final initial = platform.publishCount;

    store.updateNoteContent('n1', title: 'Second');
    await settleBridge();

    expect(platform.publishCount, greaterThan(initial));
    expect(
      (platform.publishedNotes['n1'] as Map<String, dynamic>)['title'],
      'Second',
    );
  });

  test('keeps publishing a stale note a widget still wants', () async {
    api.notes['old'] = serverNote(
      'old',
      title: 'Pinned long ago',
      updatedAt: DateTime.utc(2020, 1, 1),
    );
    api.notes['new'] = serverNote(
      'new',
      title: 'Recent',
      updatedAt: DateTime.utc(2026, 6, 1),
    );
    await store.load();
    platform.wanted = ['old'];

    bridge = buildBridge()..start();
    await settleBridge();

    expect(platform.publishedNotes.keys, containsAll(['old', 'new']));
  });

  test('publishes nothing until the notes have loaded', () async {
    bridge = buildBridge()..start();
    await settleBridge();

    // A pass mid-load would blank every widget until the notes arrive.
    expect(platform.publishCount, 0);
  });

  test('clear wipes what this account put on the home screen', () async {
    api.notes['n1'] = serverNote('n1', title: 'Secret');
    await store.load();
    bridge = buildBridge()..start();
    await settleBridge();

    await bridge.clear();

    expect(platform.clearAllCount, 1);
    expect(platform.session, isNull);
  });

  test('stops publishing once disposed', () async {
    api.notes['n1'] = serverNote('n1', title: 'First');
    await store.load();
    bridge = buildBridge()..start();
    await settleBridge();
    final afterStart = platform.publishCount;

    bridge.dispose();
    store.updateNoteContent('n1', title: 'Second');
    await settleBridge();

    expect(platform.publishCount, afterStart);
  });
}
