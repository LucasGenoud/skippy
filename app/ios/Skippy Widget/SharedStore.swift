import Foundation

/// The App Group store the app publishes notes into and this widget reads.
///
/// The keys and the payload shape are a contract with `widget_payload.dart`
/// (and with the Kotlin side on Android); changing one means changing all of
/// them. Everything here is deliberately tolerant: this parses a document
/// another language wrote, and a widget that renders nothing is a worse failure
/// than one that renders a note with a field missing.
enum SharedStore {
  static let appGroupId = "group.com.lucasgenoud.skippy"

  enum Key {
    static let notes = "skippy_widget_notes"
    static let index = "skippy_widget_index"
    static let session = "skippy_widget_session"
    static let ops = "skippy_widget_ops"
    static let wanted = "skippy_widget_wanted"
  }

  /// How many ids are remembered as "some widget wants this note". Bounded so a
  /// note deleted long ago can't keep the app publishing forever.
  private static let maxWantedIds = 20

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupId)
  }

  // MARK: - Raw JSON access

  /// Values are written by the Flutter side as JSON strings, so every read goes
  /// through a decode rather than reading a plist type directly.
  private static func readJSON(_ key: String) -> Any? {
    guard let raw = defaults?.string(forKey: key),
      let data = raw.data(using: .utf8)
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [])
  }

  private static func writeJSON(_ value: Any, forKey key: String) {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: []),
      let text = String(data: data, encoding: .utf8)
    else { return }
    defaults?.set(text, forKey: key)
  }

  // MARK: - Notes

  private static func notesMap() -> [String: Any] {
    guard let doc = readJSON(Key.notes) as? [String: Any],
      let notes = doc["notes"] as? [String: Any]
    else { return [:] }
    return notes
  }

  /// The note a widget is configured to show, or nil if the app has not
  /// published it (yet, or ever).
  static func note(id: String) -> WidgetNote? {
    guard let raw = notesMap()[id] as? [String: Any] else {
      // Tell the app we still need this one: it publishes a bounded set of
      // recent notes, and a widget can outlive a note's stay in that window.
      markWanted(id: id)
      return nil
    }
    return WidgetNote(json: raw)
  }

  /// The picker list backing the widget's note chooser.
  static func index() -> [NoteSummary] {
    guard let rows = readJSON(Key.index) as? [[String: Any]] else { return [] }
    return rows.compactMap(NoteSummary.init(json:))
  }

  /// Record that a widget wanted a note the app has not published.
  private static func markWanted(id: String) {
    var ids = (readJSON(Key.wanted) as? [String])?.filter { !$0.isEmpty } ?? []
    guard !ids.contains(id) else { return }
    ids.append(id)
    if ids.count > maxWantedIds {
      ids = Array(ids.suffix(maxWantedIds))
    }
    writeJSON(ids, forKey: Key.wanted)
  }

  // MARK: - Ticking an item

  /// Flip one checklist item in the published document.
  ///
  /// Mutates the decoded JSON rather than re-encoding a typed struct, so fields
  /// this version of the widget does not know about survive the write.
  /// Returns the note's full item list afterwards, which is what the server
  /// patch has to send.
  @discardableResult
  static func setItemDone(noteId: String, itemId: String, done: Bool) -> [[String: Any]]? {
    guard var doc = readJSON(Key.notes) as? [String: Any],
      var notes = doc["notes"] as? [String: Any],
      var note = notes[noteId] as? [String: Any],
      var items = note["items"] as? [[String: Any]]
    else { return nil }

    var found = false
    for index in items.indices where items[index]["id"] as? String == itemId {
      items[index]["done"] = done
      found = true
    }
    guard found else { return nil }

    note["items"] = items
    note["pendingCount"] = items.filter { ($0["done"] as? Bool) != true }.count
    notes[noteId] = note
    doc["notes"] = notes
    writeJSON(doc, forKey: Key.notes)
    return items
  }

  // MARK: - The outbound queue

  /// Queue a tick so the app can replay it if this process cannot reach the
  /// server. Every op names an absolute state, so replaying one twice is safe.
  static func appendOp(id: String, noteId: String, itemId: String, done: Bool) {
    var ops = (readJSON(Key.ops) as? [[String: Any]]) ?? []
    ops.append([
      "opId": id,
      "noteId": noteId,
      "itemId": itemId,
      "done": done,
      "at": ISO8601DateFormatter().string(from: Date()),
    ])
    writeJSON(ops, forKey: Key.ops)
  }

  /// Drop one op once the server has taken it.
  static func removeOp(id: String) {
    guard let ops = readJSON(Key.ops) as? [[String: Any]] else { return }
    writeJSON(ops.filter { ($0["opId"] as? String) != id }, forKey: Key.ops)
  }

  // MARK: - Session

  /// The server and credential to sync a tick with, mirrored by the app. Absent
  /// when signed out, in which case a tick waits in the queue instead.
  static func session() -> (baseUrl: String, token: String)? {
    guard let raw = readJSON(Key.session) as? [String: Any],
      let baseUrl = raw["baseUrl"] as? String,
      let token = raw["token"] as? String,
      !baseUrl.isEmpty, !token.isEmpty
    else { return nil }
    return (baseUrl, token)
  }
}

/// One checklist row on a widget.
struct WidgetItem: Identifiable, Hashable {
  let id: String
  let text: String
  let done: Bool
}

/// A note trimmed to what a widget can render.
struct WidgetNote {
  let id: String
  let title: String
  let kind: String
  let colorLight: String?
  let colorDark: String?
  let items: [WidgetItem]
  /// Totals for the whole note, not the published slice, so "+N more" is honest.
  let itemCount: Int
  let pendingCount: Int
  let content: String

  var isChecklist: Bool { kind == "checklist" }

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, !id.isEmpty else { return nil }
    self.id = id
    title = (json["title"] as? String) ?? "Untitled note"
    kind = (json["kind"] as? String) ?? "text"
    colorLight = json["colorLight"] as? String
    colorDark = json["colorDark"] as? String
    content = (json["content"] as? String) ?? ""
    let rows = (json["items"] as? [[String: Any]]) ?? []
    items = rows.compactMap { row in
      guard let itemId = row["id"] as? String, !itemId.isEmpty else { return nil }
      return WidgetItem(
        id: itemId,
        text: (row["text"] as? String) ?? "",
        done: (row["done"] as? Bool) ?? false
      )
    }
    itemCount = (json["itemCount"] as? Int) ?? items.count
    pendingCount =
      (json["pendingCount"] as? Int) ?? items.filter { !$0.done }.count
  }
}

/// A row in the widget's note picker.
struct NoteSummary {
  let id: String
  let title: String
  let kind: String
  let itemCount: Int
  let pendingCount: Int

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, !id.isEmpty else { return nil }
    self.id = id
    title = (json["title"] as? String) ?? "Untitled note"
    kind = (json["kind"] as? String) ?? "text"
    itemCount = (json["itemCount"] as? Int) ?? 0
    pendingCount = (json["pendingCount"] as? Int) ?? 0
  }

  /// The subtitle under a picker row: enough to tell two similar lists apart.
  var subtitle: String? {
    guard kind == "checklist", itemCount > 0 else { return nil }
    return pendingCount == 0
      ? "All \(itemCount) done"
      : "\(pendingCount) of \(itemCount) left"
  }
}
