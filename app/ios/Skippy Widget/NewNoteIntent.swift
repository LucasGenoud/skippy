import AppIntents
import Foundation

/// Where a new-note intent hands its link once it runs inside the app.
///
/// This file belongs to both the app and the widget extension: the extension
/// needs the intent type for its Control Center controls, and the app needs it
/// so iOS runs the intent there, with the app open. Only the app sets this, so
/// the extension never has to know about Flutter.
enum NewNoteRouter {
  static var open: ((URL) -> Void)?
}

/// The kinds of note an outside entry point can start. The links are the
/// `skippy://new` contract in the Dart side's `launch_action.dart`.
@available(iOS 17.0, *)
enum NewNoteKind: String, AppEnum {
  case note
  case checklist
  case voice

  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Note kind"

  static var caseDisplayRepresentations: [NewNoteKind: DisplayRepresentation] = [
    .note: DisplayRepresentation(title: "Note", image: .init(systemName: NewNoteKind.note.symbol)),
    .checklist: DisplayRepresentation(
      title: "Checklist", image: .init(systemName: NewNoteKind.checklist.symbol)),
    .voice: DisplayRepresentation(
      title: "Voice note", image: .init(systemName: NewNoteKind.voice.symbol)),
  ]

  /// SF Symbol shared by the intent, its shortcuts and its controls.
  var symbol: String {
    switch self {
    case .note: return "square.and.pencil"
    case .checklist: return "checklist"
    case .voice: return "mic"
    }
  }

  /// `note` leaves the kind out, so the app starts the user's default kind.
  var link: URL {
    var components = URLComponents()
    components.scheme = "skippy"
    components.host = "new"
    components.queryItems = [URLQueryItem(name: "homeWidget", value: "1")]
    if self != .note {
      components.queryItems?.append(URLQueryItem(name: "kind", value: rawValue))
    }
    return components.url!
  }
}

/// Opens Skippy on a new note. Behind Siri, the Shortcuts app, Spotlight, and
/// the Control Center and Action Button controls.
@available(iOS 17.0, *)
struct NewNoteIntent: AppIntent {
  static var title: LocalizedStringResource = "New Note"
  static var description = IntentDescription("Opens Skippy on a new note.")

  /// The note is written in the app, so the app has to come forward.
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Kind", default: .note)
  var kind: NewNoteKind

  init() {}

  init(kind: NewNoteKind) {
    self.kind = kind
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    NewNoteRouter.open?(kind.link)
    return .result()
  }
}
