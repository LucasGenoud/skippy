import AppIntents
import WidgetKit

/// The note a widget instance shows, chosen in the widget's own edit sheet.
///
/// iOS gives an app no way to place a widget, so this picker is where the note
/// actually gets chosen. Its rows come from the index the app publishes, which
/// means the list is available instantly and offline.
struct NoteEntity: AppEntity, Identifiable {
  let id: String
  let title: String
  let subtitle: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Note")
  }

  static var defaultQuery = NoteQuery()

  var displayRepresentation: DisplayRepresentation {
    if let subtitle {
      return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
    return DisplayRepresentation(title: "\(title)")
  }

  init(id: String, title: String, subtitle: String? = nil) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
  }

  init(summary: NoteSummary) {
    self.init(id: summary.id, title: summary.title, subtitle: summary.subtitle)
  }
}

struct NoteQuery: EntityQuery {
  /// Resolves the ids iOS has stored in existing widget configurations. A note
  /// that has since fallen out of the published index still resolves to its id,
  /// so an existing widget keeps its selection instead of silently resetting.
  func entities(for identifiers: [String]) async throws -> [NoteEntity] {
    let byId = Dictionary(
      SharedStore.index().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return identifiers.map { id in
      if let summary = byId[id] { return NoteEntity(summary: summary) }
      return NoteEntity(id: id, title: "Note")
    }
  }

  func suggestedEntities() async throws -> [NoteEntity] {
    SharedStore.index().map(NoteEntity.init(summary:))
  }

  func defaultResult() async -> NoteEntity? {
    SharedStore.index().first.map(NoteEntity.init(summary:))
  }
}

/// The widget's configuration: which note to show.
struct SelectNoteIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Choose Note"
  static var description = IntentDescription("Show one of your Skippy notes.")

  @Parameter(title: "Note")
  var note: NoteEntity?

  init() {}

  init(note: NoteEntity?) {
    self.note = note
  }
}
