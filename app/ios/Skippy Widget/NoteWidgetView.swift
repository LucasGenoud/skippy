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
  /// heights, against the tallest thing in a row (the `.title3` checkbox, ~25pt)
  /// plus its 5pt spacing, under a `.title3` title.
  private var rowLimit: Int {
    switch family {
    case .systemSmall: return 2
    case .systemMedium: return 3
    default: return 8
    }
  }

  /// Whether the checklist gets its own "Add item" row.
  ///
  /// Only above the small family: there the whole widget is a single tap
  /// target driven by `widgetURL`, and a `Link` inside it is ignored, so an
  /// add row would look tappable and open the note plain instead.
  private var showsAddRow: Bool { family != .systemSmall }

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
        .font(.title3.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.primary)

      if note.isChecklist {
        // The add row costs one item's worth of height, so give it one back.
        ChecklistBody(
          note: note,
          limit: showsAddRow ? rowLimit - 1 : rowLimit,
          showsAddRow: showsAddRow
        )
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
  let showsAddRow: Bool

  var body: some View {
    let shown = Array(note.items.prefix(limit))
    let hidden = note.itemCount - shown.count

    VStack(alignment: .leading, spacing: 5) {
      if note.items.isEmpty {
        Text("No items")
          .font(.body)
          .foregroundStyle(.secondary)
      } else {
        ForEach(shown) { item in
          ChecklistRow(noteId: note.id, item: item)
        }
        if hidden > 0 {
          Text("+\(hidden) more")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if showsAddRow {
        AddItemRow(noteId: note.id)
      }
    }
  }
}

/// Opens the note with an empty checklist row focused.
///
/// A widget cannot take text: WidgetKit has no text field, and an `AppIntent`
/// has no way to prompt for one. So this hands the typing to the app rather
/// than pretending to accept it here, which still saves the user finding the
/// note themselves. `Link` (not `Button(intent:)`) because the work happens in
/// the app; the `homeWidget` query item is required for the same reason as on
/// the widget as a whole, and `add=1` is what the app reads to focus the row.
@available(iOS 17.0, *)
private struct AddItemRow: View {
  let noteId: String

  var body: some View {
    if let url = URL(string: "skippy://note/\(noteId)?homeWidget=1&add=1") {
      Link(destination: url) {
        HStack(spacing: 8) {
          // Sized like a row's checkbox so the two line up in the same column.
          Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .frame(width: 20)
          Text("Add item")
            .font(.body)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        // The whole row responds, not just the glyph and its label.
        .contentShape(Rectangle())
      }
    }
  }
}

/// One tickable row. Only the checkbox and its visible label are buttons; the
/// empty remainder of the row keeps the widget's normal open-note behavior.
@available(iOS 17.0, *)
private struct ChecklistRow: View {
  let noteId: String
  let item: WidgetItem

  var body: some View {
    let intent = ToggleItemIntent(noteId: noteId, itemId: item.id, done: !item.done)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Button(intent: intent) {
        // A home screen is read at arm's length and ticked with a thumb, so
        // both the box and its label run a size larger than a compact list
        // would: .title3 for the target, .body for the text.
        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(item.done ? .secondary : .primary)
      }
      .buttonStyle(.plain)
      Button(intent: intent) {
        Text(item.text)
          .font(.body)
          .lineLimit(1)
          .strikethrough(item.done, color: .secondary)
          .foregroundStyle(item.done ? .secondary : .primary)
      }
      .buttonStyle(.plain)
      Spacer(minLength: 0)
    }
  }
}

@available(iOS 17.0, *)
private struct TextBody: View {
  let note: WidgetNote
  let limit: Int

  var body: some View {
    if note.content.isEmpty {
      Text("Empty note")
        .font(.body)
        .foregroundStyle(.secondary)
    } else {
      Text(note.content)
        .font(.body)
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
