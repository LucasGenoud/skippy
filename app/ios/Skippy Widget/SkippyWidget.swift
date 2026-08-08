import AppIntents
import SwiftUI
import WidgetKit

/// Identifies this widget to `WidgetCenter`. Must match `kIOSWidgetKind` in
/// the Dart side's `home_widgets.dart`, which is what asks it to reload.
let kSkippyWidgetKind = "SkippyNoteWidget"

/// One render of a note.
struct NoteEntry: TimelineEntry {
  let date: Date
  /// nil when no note is configured yet, or the app has not published it.
  let note: WidgetNote?
  let configuredNoteId: String?
}

@available(iOS 17.0, *)
struct SkippyWidgetProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> NoteEntry {
    NoteEntry(date: Date(), note: nil, configuredNoteId: nil)
  }

  func snapshot(for configuration: SelectNoteIntent, in context: Context) async -> NoteEntry {
    cachedEntry(for: configuration)
  }

  /// Fetch the selected note periodically as well as accepting immediate
  /// reloads from the app. WidgetKit chooses the exact time, but this gives a
  /// widget a chance to catch edits from another device while Skippy itself is
  /// not running. The cached App Group payload remains the offline fallback.
  func timeline(for configuration: SelectNoteIntent, in context: Context) async -> Timeline<
    NoteEntry
  > {
    let cached = cachedEntry(for: configuration)
    let refreshed: NoteEntry
    if let id = cached.configuredNoteId, !SharedStore.hasPendingOp(noteId: id) {
      switch await WidgetSync.fetchNote(noteId: id, cached: cached.note) {
      case .current(let note):
        refreshed = NoteEntry(date: Date(), note: note, configuredNoteId: id)
      case .unavailable:
        refreshed = NoteEntry(date: Date(), note: nil, configuredNoteId: id)
      case .failed:
        refreshed = cached
      }
    } else {
      refreshed = cached
    }
    // WidgetKit schedules this opportunistically, not as a real-time timer.
    // Fifteen minutes is its recommended lower bound for timeline refreshes.
    return Timeline(
      entries: [refreshed],
      policy: .after(Date().addingTimeInterval(15 * 60))
    )
  }

  private func cachedEntry(for configuration: SelectNoteIntent) -> NoteEntry {
    let id = configuration.note?.id
    return NoteEntry(
      date: Date(),
      note: id.flatMap { SharedStore.note(id: $0) },
      configuredNoteId: id
    )
  }
}

@available(iOS 17.0, *)
struct SkippyWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kSkippyWidgetKind,
      intent: SelectNoteIntent.self,
      provider: SkippyWidgetProvider()
    ) { entry in
      NoteWidgetView(entry: entry)
        .containerBackground(for: .widget) {
          NoteBackground(note: entry.note)
        }
    }
    .configurationDisplayName("Note")
    .description("Keep a note on your Home Screen. Checklists can be ticked here.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

@main
struct SkippyWidgetBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 17.0, *) {
      SkippyWidget()
    }
  }
}
