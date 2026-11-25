import AppIntents

/// What Siri, Spotlight and the Shortcuts app offer without any setup.
///
/// Every phrase must name the app, which is what lets Siri route it here.
@available(iOS 17.0, *)
struct SkippyShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: NewNoteIntent(kind: .note),
      phrases: [
        "New note in \(.applicationName)",
        "Create a \(.applicationName) note",
        "Start a note in \(.applicationName)",
      ],
      shortTitle: "New Note",
      systemImageName: "square.and.pencil"
    )
    AppShortcut(
      intent: NewNoteIntent(kind: .checklist),
      phrases: [
        "New checklist in \(.applicationName)",
        "Create a \(.applicationName) checklist",
        "New list in \(.applicationName)",
      ],
      shortTitle: "New Checklist",
      systemImageName: "checklist"
    )
    AppShortcut(
      intent: NewNoteIntent(kind: .voice),
      phrases: [
        "Record a voice note in \(.applicationName)",
        "New voice note in \(.applicationName)",
        "Record in \(.applicationName)",
      ],
      shortTitle: "Voice Note",
      systemImageName: "mic"
    )
  }
}
