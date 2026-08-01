import SwiftUI
import WidgetKit

/// The note's colour behind the widget, falling back to the system material so
/// an uncoloured note still reads as a card rather than a hole.
@available(iOS 17.0, *)
struct NoteBackground: View {
  let note: WidgetNote?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let hex = scheme == .dark ? note?.colorDark : note?.colorLight
    if let color = Color(hex: hex) {
      color
    } else {
      Color(uiColor: .systemBackground)
    }
  }
}

/// What a Skippy widget shows.
///
/// WidgetKit has no scroll view at any size, so a long checklist cannot be
/// scrolled here the way it can in the app (or on Android). The response is to
/// show the items that matter: pending ones first (the app publishes them in
/// that order), as many as the family fits, then an honest "+N more" that opens
/// the note.
@available(iOS 17.0, *)
struct NoteWidgetView: View {
  let entry: NoteEntry
  @Environment(\.widgetFamily) private var family

  /// Rows that fit without clipping. Measured against the standard widget
  /// heights; a row is a single line of body text plus its spacing.
  private var rowLimit: Int {
    switch family {
    case .systemSmall: return 3
    case .systemMedium: return 4
    default: return 10
    }
  }

  var body: some View {
    if let note = entry.note {
      content(for: note)
        // The `homeWidget` query item is not decoration: the home_widget plugin
        // ignores any launch URL that does not carry it, so a link without it
        // opens the app but never reaches Dart.
        .widgetURL(URL(string: "skippy://note/\(note.id)?homeWidget=1"))
    } else {
      EmptyStateView(hasSelection: entry.configuredNoteId != nil)
    }
  }

  @ViewBuilder
  private func content(for note: WidgetNote) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(note.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.primary)

      if note.isChecklist {
        ChecklistBody(note: note, limit: rowLimit)
      } else {
        TextBody(note: note, limit: rowLimit)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

@available(iOS 17.0, *)
private struct ChecklistBody: View {
  let note: WidgetNote
  let limit: Int

  var body: some View {
    let shown = Array(note.items.prefix(limit))
    let hidden = note.itemCount - shown.count

    if note.items.isEmpty {
      Text("No items")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(shown) { item in
          ChecklistRow(noteId: note.id, item: item)
        }
        if hidden > 0 {
          Text("+\(hidden) more")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// One tickable row.
///
/// The whole row is the button, not just the box: a checkbox alone is a small
/// target on a home screen, and the text beside it is the thing being aimed at.
@available(iOS 17.0, *)
private struct ChecklistRow: View {
  let noteId: String
  let item: WidgetItem

  var body: some View {
    Button(intent: ToggleItemIntent(noteId: noteId, itemId: item.id, done: !item.done)) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
          .font(.caption)
          .foregroundStyle(item.done ? .secondary : .primary)
        Text(item.text)
          .font(.caption)
          .lineLimit(1)
          .strikethrough(item.done, color: .secondary)
          .foregroundStyle(item.done ? .secondary : .primary)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

@available(iOS 17.0, *)
private struct TextBody: View {
  let note: WidgetNote
  let limit: Int

  var body: some View {
    if note.content.isEmpty {
      Text("Empty note")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text(note.content)
        .font(.caption)
        // One extra line than a checklist fits: no checkboxes to make room for.
        .lineLimit(limit + 1)
        .foregroundStyle(.primary)
    }
  }
}

/// Shown before a note is chosen, and when the chosen note has not been
/// published yet. Both are fixed by the user doing something specific, so the
/// text says which.
@available(iOS 17.0, *)
private struct EmptyStateView: View {
  let hasSelection: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: "note.text")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(hasSelection ? "Open Skippy to sync this note" : "Choose a note")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !hasSelection {
        Text("Touch and hold, then Edit Widget.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension Color {
  /// Parses the `#RRGGBB` the app publishes. Returns nil for anything else, so
  /// a malformed colour falls back to the default background rather than black.
  init?(hex: String?) {
    guard var value = hex else { return nil }
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
    self.init(
      .sRGB,
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      opacity: 1
    )
  }
}
