import '../models/note.dart';
import 'linkify.dart';

/// Parsing for the search box, where `label:work is:pinned milk` narrows by
/// structure as well as by text.
///
/// Kept pure and free of any widget so the rules can be unit tested, and so
/// the same parse drives filtering, match highlighting, and saved smart views
/// (whose whole definition is one of these query strings).

/// The `field:` prefixes the box understands.
///
/// Unknown prefixes are deliberately NOT operators: `https://example.com`
/// would otherwise parse as the field `https` with the value `//example.com`
/// and stop matching the note that contains it. Anything not listed here stays
/// free text.
enum FilterField {
  label(['label', 'tag']),
  state(['is']),
  has(['has']),
  color(['color', 'colour']),
  kind(['kind', 'type']);

  /// Every spelling that addresses this field, first one canonical.
  final List<String> keywords;
  const FilterField(this.keywords);

  String get keyword => keywords.first;

  static FilterField? fromKeyword(String word) {
    for (final field in values) {
      if (field.keywords.contains(word)) return field;
    }
    return null;
  }
}

/// Values `is:` accepts. Anything else matches nothing, so a typo shows an
/// empty result rather than silently widening the search.
const List<String> kStateValues = [
  'pinned',
  'archived',
  'trashed',
  'shared',
  'done',
  'open',
];

/// Values `has:` accepts.
const List<String> kHasValues = [
  'reminder',
  'attachment',
  'image',
  'audio',
  'link',
  'label',
];

/// One `field:value` term, optionally negated with a leading `-`.
class SearchFilter {
  final FilterField field;

  /// Lowercased, quotes already stripped.
  final String value;
  final bool negated;

  const SearchFilter({
    required this.field,
    required this.value,
    this.negated = false,
  });

  @override
  bool operator ==(Object other) =>
      other is SearchFilter &&
      other.field == field &&
      other.value == value &&
      other.negated == negated;

  @override
  int get hashCode => Object.hash(field, value, negated);

  @override
  String toString() => '${negated ? '-' : ''}${field.keyword}:$value';
}

/// One run of free text. Quoted runs keep their spaces, so `"buy milk"` is a
/// single term rather than two.
class SearchTerm {
  final String text;
  final bool negated;

  const SearchTerm(this.text, {this.negated = false});

  @override
  bool operator ==(Object other) =>
      other is SearchTerm && other.text == text && other.negated == negated;

  @override
  int get hashCode => Object.hash(text, negated);

  @override
  String toString() => '${negated ? '-' : ''}$text';
}

/// Which note state an explicit `is:` filter asks a view to reveal.
enum StateOverride { archived, trashed }

/// A parsed query. Every term and filter has to match (they are ANDed), which
/// is what makes adding one more word always narrow the result.
class SearchQuery {
  final List<SearchTerm> terms;
  final List<SearchFilter> filters;

  const SearchQuery({this.terms = const [], this.filters = const []});

  static const empty = SearchQuery();

  bool get isEmpty => terms.isEmpty && filters.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// The positive free text alone, for match highlighting. Highlighting the
  /// raw string would tint `label:` and the label's name inside unrelated
  /// words; with no operators typed this is byte for byte the old behaviour.
  String get text =>
      terms.where((t) => !t.negated).map((t) => t.text).join(' ');

  /// The state an explicit, positive `is:` filter asks for, when it is one a
  /// view would otherwise hide. This is what lets `is:archived` typed in the
  /// notes view find archived notes instead of matching nothing: the filter is
  /// more specific than the view's default, so it wins.
  ///
  /// Negated filters never override; `-is:archived` narrows what the view
  /// already shows rather than asking for a different set.
  StateOverride? get stateOverride {
    var archived = false;
    for (final f in filters) {
      if (f.field != FilterField.state || f.negated) continue;
      if (f.value == 'trashed') return StateOverride.trashed;
      if (f.value == 'archived') archived = true;
    }
    return archived ? StateOverride.archived : null;
  }

  /// Terms the parser recognized as operators but cannot satisfy, so the box
  /// can say why nothing matched instead of just showing an empty grid.
  List<SearchFilter> get unknownFilters => filters
      .where(
        (f) => switch (f.field) {
          FilterField.state => !kStateValues.contains(f.value),
          FilterField.has => !kHasValues.contains(f.value),
          FilterField.kind => NoteKind.values.every((k) => k.wire != f.value),
          FilterField.label || FilterField.color => false,
        },
      )
      .toList();

  bool matches(Note note, SearchContext context) {
    for (final term in terms) {
      if (_containsText(note, term.text, context) == term.negated) return false;
    }
    for (final filter in filters) {
      if (_matchesFilter(note, filter, context) == filter.negated) return false;
    }
    return true;
  }
}

/// The workspace-scoped facts a query needs beyond the note itself. Built once
/// per selection pass rather than per note.
class SearchContext {
  final Map<String, Label> labelsById;

  /// Lowercased label name to the ids carrying it. A name can repeat across
  /// workspaces, so `label:work` has to accept any of them and let the
  /// workspace scope do the narrowing.
  final Map<String, Set<String>> labelIdsByName;

  const SearchContext._(this.labelsById, this.labelIdsByName);

  factory SearchContext(Iterable<Label> labels) {
    final byId = <String, Label>{};
    final byName = <String, Set<String>>{};
    for (final label in labels) {
      byId[label.id] = label;
      byName.putIfAbsent(label.name.toLowerCase(), () => {}).add(label.id);
    }
    return SearchContext._(byId, byName);
  }

  static final empty = SearchContext(const []);
}

/// Split on whitespace, except inside double quotes. Quotes are consumed, so
/// `label:"to do"` arrives as the single token `label:to do`.
List<String> _tokenize(String input) {
  final out = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (ch == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && (ch == ' ' || ch == '\t' || ch == '\n')) {
      if (buffer.isNotEmpty) {
        out.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(ch);
  }
  if (buffer.isNotEmpty) out.add(buffer.toString());
  return out;
}

SearchQuery parseSearchQuery(String input) {
  final terms = <SearchTerm>[];
  final filters = <SearchFilter>[];
  for (final token in _tokenize(input)) {
    var body = token;
    var negated = false;
    // A lone `-` is text, not a negation of nothing.
    if (body.length > 1 && body.startsWith('-')) {
      negated = true;
      body = body.substring(1);
    }
    final colon = body.indexOf(':');
    if (colon > 0) {
      final field = FilterField.fromKeyword(
        body.substring(0, colon).toLowerCase(),
      );
      final value = body.substring(colon + 1).trim().toLowerCase();
      if (field != null && value.isNotEmpty) {
        filters.add(SearchFilter(field: field, value: value, negated: negated));
        continue;
      }
    }
    final text = body.trim().toLowerCase();
    if (text.isNotEmpty) terms.add(SearchTerm(text, negated: negated));
  }
  return SearchQuery(terms: terms, filters: filters);
}

bool _containsText(Note note, String needle, SearchContext context) {
  if (note.title.toLowerCase().contains(needle)) return true;
  if (note.content.toLowerCase().contains(needle)) return true;
  if (note.items.any((item) => item.text.toLowerCase().contains(needle))) {
    return true;
  }
  return note.labelIds.any(
    (id) =>
        context.labelsById[id]?.name.toLowerCase().contains(needle) ?? false,
  );
}

bool _matchesFilter(Note note, SearchFilter filter, SearchContext context) =>
    switch (filter.field) {
      FilterField.label => _matchesLabel(note, filter.value, context),
      FilterField.state => _matchesState(note, filter.value),
      FilterField.has => _matchesHas(note, filter.value),
      FilterField.color => note.color.toLowerCase() == filter.value,
      FilterField.kind => note.kind.wire == filter.value,
    };

bool _matchesLabel(Note note, String value, SearchContext context) {
  if (value == 'none') return note.labelIds.isEmpty;
  if (value == 'any') return note.labelIds.isNotEmpty;
  final ids = context.labelIdsByName[value];
  if (ids == null) return false;
  return note.labelIds.any(ids.contains);
}

bool _matchesState(Note note, String value) => switch (value) {
  'pinned' => note.pinned,
  'archived' => note.archived,
  'trashed' => note.trashed,
  'shared' => note.isShared,
  // A checklist counts as done only once it has items and none are pending,
  // so an empty list is not "everything done".
  'done' =>
    note.isChecklist &&
        note.items.isNotEmpty &&
        note.items.every((i) => i.done),
  'open' => note.items.any((i) => !i.done),
  _ => false,
};

bool _matchesHas(Note note, String value) => switch (value) {
  'reminder' => note.reminderAt != null,
  'attachment' => note.attachments.isNotEmpty,
  'image' => note.attachments.any((a) => a.isImage),
  'audio' => note.attachments.any((a) => a.isAudio),
  'label' => note.labelIds.isNotEmpty,
  'link' =>
    findUrls(note.content).isNotEmpty || findUrls(note.title).isNotEmpty,
  _ => false,
};
