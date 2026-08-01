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
    entry(for: configuration)
  }

  /// A single entry with no refresh date.
  ///
  /// Everything a widget shows comes out of the App Group, and both writers of
  /// that store (the app publishing, an intent ticking) reload the timeline
  /// themselves. There is nothing for a scheduled wake-up to discover, so
  /// asking for one would only spend the widget's refresh budget.
  func timeline(for configuration: SelectNoteIntent, in context: Context) async -> Timeline<
    NoteEntry
  > {
    Timeline(entries: [entry(for: configuration)], policy: .never)
  }

  private func entry(for configuration: SelectNoteIntent) -> NoteEntry {
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
