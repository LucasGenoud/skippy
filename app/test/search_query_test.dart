import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_collection.dart';
import 'package:skippy/util/search_query.dart';

void main() {
  final created = DateTime(2026, 1, 1);

  Note note(
    String id, {
    String title = '',
    String content = '',
    List<ChecklistItem> items = const [],
    NoteKind kind = NoteKind.text,
    String color = 'default',
    bool pinned = false,
    bool archived = false,
    bool trashed = false,
    DateTime? reminderAt,
    Set<String> labelIds = const {},
    List<Attachment> attachments = const [],
    List<UserRef> collaborators = const [],
    String ownerId = 'me',
  }) => Note(
    id: id,
    title: title,
    content: content,
    items: items,
    kind: kind,
    color: color,
    pinned: pinned,
    archived: archived,
    trashed: trashed,
    reminderAt: reminderAt,
    labelIds: labelIds,
    attachments: attachments,
    collaborators: collaborators,
    owner: UserRef(id: ownerId, name: ownerId),
    createdAt: created,
    updatedAt: created,
  );

  const labels = [
    Label(id: 'l-work', name: 'Work'),
    Label(id: 'l-todo', name: 'To do'),
  ];
  final context = SearchContext(labels);

  group('parsing', () {
    test('splits free text from operators', () {
      final q = parseSearchQuery('milk label:work is:pinned eggs');
      expect(q.terms.map((t) => t.text), ['milk', 'eggs']);
      expect(q.filters, [
        const SearchFilter(field: FilterField.label, value: 'work'),
        const SearchFilter(field: FilterField.state, value: 'pinned'),
      ]);
      expect(q.text, 'milk eggs');
    });

    test('keeps quoted values together and strips the quotes', () {
      final q = parseSearchQuery('label:"to do" "buy milk"');
      expect(q.filters.single.value, 'to do');
      expect(q.terms.single.text, 'buy milk');
    });

    test('reads a leading dash as negation, on text and on filters', () {
      final q = parseSearchQuery('-is:pinned -milk');
      expect(q.filters.single.negated, isTrue);
      expect(q.terms.single, const SearchTerm('milk', negated: true));
      // A negated term is not something to highlight.
      expect(q.text, '');
    });

    test('leaves an unknown prefix as text so URLs keep matching', () {
      final q = parseSearchQuery('https://example.com/x');
      expect(q.filters, isEmpty);
      expect(q.terms.single.text, 'https://example.com/x');
    });

    test('accepts aliases and is case insensitive', () {
      final q = parseSearchQuery('TAG:Work TYPE:Checklist');
      expect(q.filters, [
        const SearchFilter(field: FilterField.label, value: 'work'),
        const SearchFilter(field: FilterField.kind, value: 'checklist'),
      ]);
    });

    test('reports operators it cannot satisfy', () {
      expect(parseSearchQuery('is:pinned').unknownFilters, isEmpty);
      expect(
        parseSearchQuery('is:favourite has:sketch kind:drawing').unknownFilters
            .map((f) => f.value),
        ['favourite', 'sketch', 'drawing'],
      );
      // A label that does not exist is a normal empty result, not a typo the
      // box should complain about: labels come and go.
      expect(parseSearchQuery('label:nope').unknownFilters, isEmpty);
    });
  });

  group('matching', () {
    test('label: resolves the name, with none/any for the edges', () {
      final labelled = note('a', labelIds: {'l-work'});
      final bare = note('b');
      expect(parseSearchQuery('label:work').matches(labelled, context), isTrue);
      expect(parseSearchQuery('label:work').matches(bare, context), isFalse);
      expect(parseSearchQuery('label:"to do"').matches(labelled, context),
          isFalse);
      expect(parseSearchQuery('label:none').matches(bare, context), isTrue);
      expect(parseSearchQuery('label:any').matches(labelled, context), isTrue);
    });

    test('is: covers pin, share and checklist progress', () {
      final pinned = note('a', pinned: true);
      expect(parseSearchQuery('is:pinned').matches(pinned, context), isTrue);
      expect(parseSearchQuery('-is:pinned').matches(pinned, context), isFalse);

      final shared = note(
        'b',
        collaborators: const [UserRef(id: 'u2', name: 'Ada')],
      );
      expect(parseSearchQuery('is:shared').matches(shared, context), isTrue);

      final done = note(
        'c',
        kind: NoteKind.checklist,
        items: const [ChecklistItem(id: '1', text: 'Milk', done: true)],
      );
      final open = note(
        'd',
        kind: NoteKind.checklist,
        items: const [
          ChecklistItem(id: '1', text: 'Milk', done: true),
          ChecklistItem(id: '2', text: 'Eggs'),
        ],
      );
      expect(parseSearchQuery('is:done').matches(done, context), isTrue);
      expect(parseSearchQuery('is:done').matches(open, context), isFalse);
      expect(parseSearchQuery('is:open').matches(open, context), isTrue);
      expect(parseSearchQuery('is:open').matches(done, context), isFalse);
      // An empty list is not "everything done".
      final emptyList = note('e', kind: NoteKind.checklist);
      expect(parseSearchQuery('is:done').matches(emptyList, context), isFalse);
    });

    test('has: covers reminders, attachments and links', () {
      final withReminder = note('a', reminderAt: DateTime(2026, 2, 1));
      expect(
        parseSearchQuery('has:reminder').matches(withReminder, context),
        isTrue,
      );

      final withImage = note(
        'b',
        attachments: const [Attachment(id: 'f1', mime: 'image/png')],
      );
      expect(parseSearchQuery('has:image').matches(withImage, context), isTrue);
      expect(
        parseSearchQuery('has:attachment').matches(withImage, context),
        isTrue,
      );
      expect(parseSearchQuery('has:audio').matches(withImage, context), isFalse);

      final withLink = note('c', content: 'see https://example.com for more');
      expect(parseSearchQuery('has:link').matches(withLink, context), isTrue);
      expect(
        parseSearchQuery('has:link').matches(note('d', content: 'no url here'),
            context),
        isFalse,
      );
    });

    test('color: and kind: match the note fields', () {
      final red = note('a', color: 'red', kind: NoteKind.markdown);
      expect(parseSearchQuery('color:red').matches(red, context), isTrue);
      expect(parseSearchQuery('colour:red').matches(red, context), isTrue);
      expect(parseSearchQuery('color:blue').matches(red, context), isFalse);
      expect(parseSearchQuery('kind:markdown').matches(red, context), isTrue);
      expect(parseSearchQuery('kind:text').matches(red, context), isFalse);
    });

    test('every term and filter has to match', () {
      final target = note(
        'a',
        title: 'Groceries',
        pinned: true,
        labelIds: {'l-work'},
      );
      expect(
        parseSearchQuery('grocer label:work is:pinned').matches(target, context),
        isTrue,
      );
      expect(
        parseSearchQuery('grocer label:work is:archived')
            .matches(target, context),
        isFalse,
      );
    });

    test('free text still searches title, content, items and label names', () {
      final byItem = note(
        'a',
        items: const [ChecklistItem(id: '1', text: 'Sourdough')],
      );
      expect(parseSearchQuery('sourdough').matches(byItem, context), isTrue);
      final byLabel = note('b', labelIds: {'l-work'});
      expect(parseSearchQuery('wor').matches(byLabel, context), isTrue);
    });
  });

  group('view integration', () {
    Note archived(String id) => note(id, title: id, archived: true);

    test('is:archived reveals archived notes from the notes view', () {
      final result = selectNotes(
        notes: [note('live', title: 'live'), archived('old')],
        labels: labels,
        selection: ViewSelection.notes,
        query: 'is:archived',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(result.others.map((n) => n.id), ['old']);
    });

    test('is:trashed still refuses a note the user does not own', () {
      final result = selectNotes(
        notes: [
          note('mine', trashed: true),
          note('theirs', trashed: true, ownerId: 'someone-else'),
        ],
        labels: labels,
        selection: ViewSelection.notes,
        query: 'is:trashed',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(result.others.map((n) => n.id), ['mine']);
    });

    test('a negated state filter narrows the view instead of replacing it', () {
      final result = selectNotes(
        notes: [note('a'), note('b', pinned: true), archived('c')],
        labels: labels,
        selection: ViewSelection.notes,
        query: '-is:pinned',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      // 'c' is archived, so the notes view still hides it.
      expect(result.others.map((n) => n.id), ['a']);
    });

    test('an override inside a label view keeps the label filter', () {
      final result = selectNotes(
        notes: [
          note('tagged', archived: true, labelIds: {'l-work'}),
          note('untagged', archived: true),
        ],
        labels: labels,
        selection: const ViewSelection(NoteView.label, 'l-work'),
        query: 'is:archived',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(result.others.map((n) => n.id), ['tagged']);
    });

    test('the archive view is unaffected by an is: filter it already implies',
        () {
      final result = selectNotes(
        notes: [archived('a'), note('b')],
        labels: labels,
        selection: ViewSelection.archive,
        query: 'is:archived',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(result.others.map((n) => n.id), ['a']);
    });
  });
}
