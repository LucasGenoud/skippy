import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/util/launch_action.dart';

LaunchAction? parse(String link) => LaunchAction.fromUri(Uri.parse(link));

void main() {
  group('opening a note', () {
    test('reads the note id out of a widget tap', () {
      final action = parse('skippy://note/abc-123?homeWidget=1');
      expect(action, isA<OpenNoteAction>());
      action as OpenNoteAction;
      expect(action.noteId, 'abc-123');
      expect(action.addItem, isFalse);
    });

    test('the Add item row asks for a new checklist row', () {
      final action = parse('skippy://note/abc-123?homeWidget=1&add=1');
      action as OpenNoteAction;
      expect(action.noteId, 'abc-123');
      expect(action.addItem, isTrue);
    });
  });

  group('starting a note', () {
    test('no kind means the default kind', () {
      final action = parse('skippy://new?homeWidget=1');
      expect((action as NewNoteAction).kind, LaunchNoteKind.preferred);
    });

    test('reads the kinds native code sends', () {
      expect(
        (parse('skippy://new?homeWidget=1&kind=checklist') as NewNoteAction)
            .kind,
        LaunchNoteKind.checklist,
      );
      expect(
        (parse('skippy://new?homeWidget=1&kind=voice') as NewNoteAction).kind,
        LaunchNoteKind.voice,
      );
    });

    test('an unknown kind still starts a note', () {
      final action = parse('skippy://new?homeWidget=1&kind=drawing');
      expect((action as NewNoteAction).kind, LaunchNoteKind.preferred);
    });
  });

  test('ignores anything that is not one of our links', () {
    for (final link in [
      'https://example.com/note/abc',
      'skippy://settings/abc',
      'skippy://note/',
      'skippy://note',
    ]) {
      expect(parse(link), isNull, reason: link);
    }
    expect(LaunchAction.fromUri(null), isNull);
  });
}
