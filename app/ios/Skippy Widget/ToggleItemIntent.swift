import AppIntents
import WidgetKit

/// Ticks a checklist item straight from the home screen.
///
/// Three steps, in this order on purpose:
///  1. flip it in the App Group, so the widget redraws immediately and
///     correctly even with no network;
///  2. queue the change, so it cannot be lost if step 3 fails;
///  3. try to push it to the server.
///
/// Only step 3 can fail, and when it does the app replays the queued op on its
/// next launch. That ordering is what lets a tick be instant and durable at the
/// same time.
@available(iOS 17.0, *)
struct ToggleItemIntent: AppIntent {
  static var title: LocalizedStringResource = "Toggle checklist item"

  /// Keeps the tap on the home screen: opening the app to record a tick would
  /// defeat the point of the widget.
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Note")
  var noteId: String

  @Parameter(title: "Item")
  var itemId: String

  @Parameter(title: "Done")
  var done: Bool

  init() {
    noteId = ""
    itemId = ""
    done = false
  }

  init(noteId: String, itemId: String, done: Bool) {
    self.noteId = noteId
    self.itemId = itemId
    self.done = done
  }

  func perform() async throws -> some IntentResult {
    guard !noteId.isEmpty, !itemId.isEmpty else { return .result() }

    guard
      let items = SharedStore.setItemDone(
        noteId: noteId, itemId: itemId, done: done)
    else {
      // The note is not in the published document: nothing to tick, and the
      // read has already asked the app to publish it.
      return .result()
    }

    let opId = UUID().uuidString
    SharedStore.appendOp(id: opId, noteId: noteId, itemId: itemId, done: done)
    if await WidgetSync.pushItems(noteId: noteId, items: items) {
      SharedStore.removeOp(id: opId)
    }
    // Reload only after the server attempt. If it failed, the queued op makes
    // the provider retain the optimistic App Group copy instead of fetching an
    // older server version over it.
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}
