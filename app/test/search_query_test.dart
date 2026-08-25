import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/state/note_collection.dart';
import 'package:skippy/util/search_query.dart';
import 'package:skippy/widgets/search_query_controller.dart';

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

    test('reads a negative field spelling as the same filter as a dash', () {
      const excluded = SearchFilter(
        field: FilterField.has,
        value: 'link',
        negated: true,
      );
      expect(parseSearchQuery('hasnot:link').filters, [excluded]);
      expect(parseSearchQuery('-has:link').filters, [excluded]);
      expect(parseSearchQuery('HasNot:Link').filters, [excluded]);
      expect(parseSearchQuery('isnot:pinned').filters.single.negated, isTrue);
      expect(parseSearchQuery('notlabel:work').filters, [
        const SearchFilter(
          field: FilterField.label,
          value: 'work',
          negated: true,
        ),
      ]);
      expect(parseSearchQuery('nottype:audio').filters, [
        const SearchFilter(
          field: FilterField.kind,
          value: 'audio',
          negated: true,
        ),
      ]);
      // The dash and the spelling are one operator, so using both cancels out.
      expect(parseSearchQuery('-hasnot:link').filters.single.negated, isFalse);
    });

    test('a filter prints the spelling a user could have typed back', () {
      expect(
        parseSearchQuery('-has:link').filters.single.toString(),
        'hasnot:link',
      );
      expect(
        parseSearchQuery('-tag:work').filters.single.toString(),
        'notlabel:work',
      );
      expect(
        parseSearchQuery('has:link').filters.single.toString(),
        'has:link',
      );
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
        parseSearchQuery(
          'is:favourite has:sketch kind:drawing',
        ).unknownFilters.map((f) => f.value),
        ['favourite', 'sketch', 'drawing'],
      );
      // A label that does not exist is a normal empty result, not a typo the
      // box should complain about: labels come and go.
      expect(parseSearchQuery('label:nope').unknownFilters, isEmpty);
      // Excluding a value that does not exist is just as unsatisfiable, and
      // the complaint names the negative spelling.
      expect(
        parseSearchQuery('hasnot:sketch').unknownFilters.map((f) => '$f'),
        ['hasnot:sketch'],
      );
    });
  });

  group('tokens and toggling', () {
    test('tokens carry their source offsets, quotes included', () {
      const query = 'milk label:"to do" eggs';
      final tokens = tokenizeSearchQuery(query);
      expect(tokens.map((t) => t.raw), ['milk', 'label:"to do"', 'eggs']);
      expect(tokens.map((t) => t.isFilter), [false, true, false]);
      // The offsets are what the field paints its background from, so they
      // have to index the raw string exactly.
      for (final token in tokens) {
        expect(query.substring(token.start, token.end), token.raw);
      }
    });

    test('toggling adds a filter, then takes the same one back out', () {
      var query = toggleSearchFilter('', 'is:pinned');
      expect(query, 'is:pinned');
      query = toggleSearchFilter(query, 'has:reminder');
      expect(query, 'is:pinned has:reminder');
      expect(searchQueryHas(query, 'is:pinned'), isTrue);
      expect(searchQueryHas(query, 'is:open'), isFalse);

      query = toggleSearchFilter(query, 'is:pinned');
      expect(query, 'has:reminder');
      expect(searchQueryHas(query, 'is:pinned'), isFalse);
    });

    test('toggling leaves the words the user typed exactly as typed', () {
      // Re-serializing a parse would lowercase this while they are still
      // typing it, which is why removal works on raw tokens.
      const typed = 'Sourdough "Rye Bread" -Milk';
      final added = toggleSearchFilter(typed, 'is:pinned');
      expect(added, 'Sourdough "Rye Bread" -Milk is:pinned');
      expect(toggleSearchFilter(added, 'is:pinned'), typed);
    });

    test('negating a token rewrites the field, not the value', () {
      expect(negateSearchFilter('has:link'), 'hasnot:link');
      expect(negateSearchFilter('hasnot:link'), 'has:link');
      expect(negateSearchFilter('-has:link'), 'has:link');
      expect(negateSearchFilter('is:pinned'), 'isnot:pinned');
      expect(negateSearchFilter('color:red'), 'notcolor:red');
      // Quotes and the value's own capitals survive, because the label has to
      // keep matching the name it was written with.
      expect(negateSearchFilter('label:"To do"'), 'notlabel:"To do"');
      // Not a filter at all.
      expect(negateSearchFilter('milk'), 'milk');
      expect(negateSearchFilter('https://example.com'), 'https://example.com');
    });

    test('a chip cycles off, then matching, then excluding, then off', () {
      var query = cycleSearchFilter('milk', 'has:link');
      expect(query, 'milk has:link');
      query = cycleSearchFilter(query, 'has:link');
      expect(query, 'milk hasnot:link');
      query = cycleSearchFilter(query, 'has:link');
      expect(query, 'milk');
    });

    test('the excluding step rewrites the filter where it already stands', () {
      // Removing and re-appending would send it to the end of the query, past
      // filters the user picked after it.
      const query = 'is:pinned has:link kind:text';
      expect(
        cycleSearchFilter(query, 'has:link'),
        'is:pinned hasnot:link kind:text',
      );
    });

    test('a chip reads a filter typed by hand, in either spelling', () {
      expect(searchQueryHas('-has:link', 'hasnot:link'), isTrue);
      expect(searchQueryHas('hasnot:link', 'has:link'), isFalse);
      // So the cycle picks up from what is already in the box.
      expect(cycleSearchFilter('-has:link', 'has:link'), '');
    });

    test('an alias toggles the filter it means, not the text it spells', () {
      // `tag:` and `label:` are the same filter, so one removes the other.
      expect(toggleSearchFilter('tag:work', 'label:work'), '');
      expect(searchQueryHas('tag:work', 'label:work'), isTrue);
    });
  });

  group('SearchQueryController', () {
    /// The spans the field will paint for [query].
    Future<List<InlineSpan>> spansFor(WidgetTester tester, String query) async {
      final controller = SearchQueryController(text: query);
      addTearDown(controller.dispose);
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final span = controller.buildTextSpan(
        context: ctx,
        style: const TextStyle(fontSize: 14),
        withComposing: false,
      );
      return span.children ?? [span];
    }

    testWidgets('tints the operators and leaves the words plain', (
      tester,
    ) async {
      final spans = await spansFor(tester, 'milk label:work eggs');
      final tinted = [
        for (final span in spans.cast<TextSpan>())
          if (span.style?.backgroundColor != null) span.text,
      ];
      expect(tinted, ['label:work']);
      // The words around it keep the field's own style.
      expect(
        spans.cast<TextSpan>().map((s) => s.text).join(),
        'milk label:work eggs',
      );
    });

    testWidgets('an excluding operator is tinted apart from a matching one', (
      tester,
    ) async {
      final spans = await spansFor(tester, 'has:link hasnot:image -is:pinned');
      final fills = {
        for (final span in spans.cast<TextSpan>())
          if (span.style?.backgroundColor != null)
            span.text: span.style!.backgroundColor,
      };
      expect(fills['hasnot:image'], isNot(fills['has:link']));
      // The dash spelling is the same operator, so it gets the same tint.
      expect(fills['-is:pinned'], fills['hasnot:image']);
    });

    testWidgets('a query with no operators is left entirely alone', (
      tester,
    ) async {
      final spans = await spansFor(tester, 'just some words');
      final tinted = spans.cast<TextSpan>().where(
        (s) => s.style?.backgroundColor != null,
      );
      expect(tinted, isEmpty);
    });
  });

  group('matching', () {
    test('label: resolves the name, with none/any for the edges', () {
      final labelled = note('a', labelIds: {'l-work'});
      final bare = note('b');
      expect(parseSearchQuery('label:work').matches(labelled, context), isTrue);
      expect(parseSearchQuery('label:work').matches(bare, context), isFalse);
      expect(
        parseSearchQuery('label:"to do"').matches(labelled, context),
        isFalse,
      );
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
      expect(
        parseSearchQuery('has:audio').matches(withImage, context),
        isFalse,
      );

      final withLink = note('c', content: 'see https://example.com for more');
      expect(parseSearchQuery('has:link').matches(withLink, context), isTrue);
      expect(
        parseSearchQuery(
          'has:link',
        ).matches(note('d', content: 'no url here'), context),
        isFalse,
      );
    });

    test('a negative filter keeps the notes the positive one drops', () {
      final withLink = note('a', content: 'see https://example.com');
      final withoutLink = note('b', content: 'no url here');
      expect(
        parseSearchQuery('hasnot:link').matches(withoutLink, context),
        isTrue,
      );
      expect(
        parseSearchQuery('hasnot:link').matches(withLink, context),
        isFalse,
      );

      final labelled = note('c', labelIds: {'l-work'});
      expect(
        parseSearchQuery('notlabel:work').matches(labelled, context),
        isFalse,
      );
      expect(
        parseSearchQuery('notlabel:work').matches(withoutLink, context),
        isTrue,
      );

      final pinned = note('d', pinned: true);
      expect(
        parseSearchQuery('isnot:pinned').matches(pinned, context),
        isFalse,
      );
      expect(
        parseSearchQuery('isnot:pinned').matches(withoutLink, context),
        isTrue,
      );

      final red = note('e', color: 'red', kind: NoteKind.markdown);
      expect(parseSearchQuery('notcolor:red').matches(red, context), isFalse);
      expect(parseSearchQuery('notkind:text').matches(red, context), isTrue);
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
        parseSearchQuery(
          'grocer label:work is:pinned',
        ).matches(target, context),
        isTrue,
      );
      expect(
        parseSearchQuery(
          'grocer label:work is:archived',
        ).matches(target, context),
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

    test('free text reaches the words the server read out of a picture', () {
      // A photo of a receipt: nothing the user typed says "ibuprofen", so
      // without the recognized text this note would be unfindable.
      final photo = note(
        'a',
        attachments: const [
          Attachment(
            id: 'f1',
            mime: 'image/jpeg',
            ocrText: 'PHARMACY RECEIPT ibuprofen 4.20',
          ),
        ],
      );
      expect(parseSearchQuery('ibuprofen').matches(photo, context), isTrue);
      // Case-insensitive, like every other field.
      expect(parseSearchQuery('pharmacy').matches(photo, context), isTrue);
      // And it still narrows: an unrelated word matches nothing.
      expect(parseSearchQuery('aspirin').matches(photo, context), isFalse);
      // Negation covers it too, so `-ibuprofen` hides the photo.
      expect(parseSearchQuery('-ibuprofen').matches(photo, context), isFalse);

      // A picture the server has not read (or could not read) is inert.
      final unread = note(
        'b',
        attachments: const [Attachment(id: 'f2', mime: 'image/jpeg')],
      );
      expect(parseSearchQuery('ibuprofen').matches(unread, context), isFalse);
    });
  });

  group('view integration', () {
    Note archived(String id) => note(id, title: id, archived: true);

    test('is:archived reveals archived notes from the notes view', () {
      final result = selectNotes(
        notes: [
          note('live', title: 'live'),
          archived('old'),
        ],
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

    test('isnot:archived does not reveal the notes is:archived would', () {
      final result = selectNotes(
        notes: [
          note('live', title: 'live'),
          archived('old'),
        ],
        labels: labels,
        selection: ViewSelection.notes,
        query: 'isnot:archived',
        sortMode: SortMode.custom,
        currentUserId: 'me',
      );
      expect(result.others.map((n) => n.id), ['live']);
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

    test(
      'the archive view is unaffected by an is: filter it already implies',
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
      },
    );
  });
}
