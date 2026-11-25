import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action Button buttons that open Skippy on a
/// new note. One control per kind, so each can sit in its own slot.
@available(iOS 18.0, *)
struct NewNoteControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    newNoteControl(.note, title: "New Note")
  }
}

@available(iOS 18.0, *)
struct NewChecklistControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    newNoteControl(.checklist, title: "New Checklist")
  }
}

@available(iOS 18.0, *)
struct VoiceNoteControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    newNoteControl(.voice, title: "Voice Note")
  }
}

/// The kind string identifies the control to iOS, so it must never change
/// once shipped, or placed controls disappear.
@available(iOS 18.0, *)
private func newNoteControl(_ kind: NewNoteKind, title: LocalizedStringResource)
  -> some ControlWidgetConfiguration
{
  StaticControlConfiguration(kind: "com.lucasgenoud.skippy.new.\(kind.rawValue)") {
    ControlWidgetButton(action: NewNoteIntent(kind: kind)) {
      Label(title, systemImage: kind.symbol)
    }
  }
  .displayName(title)
  .description("Opens Skippy on a new note.")
}
