import '../models/note.dart';
import 'note_links.dart';

/// Whether the signed-in account existed before this session.
enum AccountOrigin { existing, justCreated }

const kStarterWelcomeTitle = 'Welcome to Skippy';
const kStarterChecklistTitle = 'Try a checklist';
const kStarterGuideTitle = 'Ways to organize';

/// Links to the other two starter notes, so `[[` is shown working.
String starterWelcomeBody({
  required String checklistId,
  required String guideId,
}) {
  final checklist = noteLinkToken(checklistId, kStarterChecklistTitle);
  final guide = noteLinkToken(guideId, kStarterGuideTitle);

  return '''
These notes will get you started. Change or delete them whenever you like.

- $checklist shows how tasks and subtasks work.
- $guide explains collections, boards, labels, and smart views.

**Things to try**

- Type `[[` in a note to link to another one.
- Keep writing offline. Your edits sync when you reconnect.
- Share a note, or invite someone to a workspace, to work on it together.''';
}

const kStarterGuideBody = '''
**Collections** keep related notes together. Each one has its own layout.

**Boards** are a collection layout. Drag notes between columns.

**Labels** cut across collections. Everyone in a workspace shares them.

**Smart views** save a search, so it stays one click away.''';

/// [newId] supplies each row's id.
List<ChecklistItem> starterChecklistItems(String Function() newId) => [
  ChecklistItem(id: newId(), text: 'Tick this box'),
  ChecklistItem(id: newId(), text: 'Plan a weekend away'),
  ChecklistItem(id: newId(), text: 'Book the train', depth: 1),
  ChecklistItem(id: newId(), text: 'Find somewhere to stay', depth: 1),
];
