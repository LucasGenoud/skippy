import Foundation

/// Pushes a tick made on the widget straight to the server.
///
/// The widget extension is its own process and cannot talk to the app, so it
/// makes the write itself rather than waiting for the app to be opened. It is
/// deliberately the *only* network call this extension makes: everything a
/// widget renders comes from what the app already published.
///
/// Failure is not an error here. The tick is already queued in the App Group,
/// and the app drains that queue on its next launch, so an offline phone or a
/// sleeping server costs nothing but a delay.
enum WidgetSync {
  /// A widget's `perform` has only moments before the extension is suspended,
  /// so a stalled request must give up rather than hold the process open.
  private static let timeout: TimeInterval = 10

  /// The result of the widget's lightweight read refresh. A reachable server
  /// that says the note is gone must clear the widget; a transient failure
  /// should leave its useful offline snapshot in place.
  enum NoteRefresh {
    case current(WidgetNote)
    case unavailable
    case failed
  }

  /// Refresh just the configured note. A WidgetKit timeline can be scheduled
  /// while the Flutter app is suspended, so reading the App Group alone would
  /// otherwise leave a widget stale after another device edits the note.
  static func fetchNote(noteId: String, cached: WidgetNote?) async -> NoteRefresh {
    guard let session = SharedStore.session() else { return .failed }
    let base = session.baseUrl.hasSuffix("/")
      ? String(session.baseUrl.dropLast())
      : session.baseUrl
    guard let baseURL = URL(string: base) else { return .failed }

    let url = baseURL
      .appendingPathComponent("api")
      .appendingPathComponent("notes")
      .appendingPathComponent(noteId)
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .failed }
      guard (200..<300).contains(http.statusCode) else {
        return (400..<500).contains(http.statusCode) ? .unavailable : .failed
      }
      guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return .failed }
      guard let note = WidgetNote(apiJSON: object, colorsFrom: cached) else {
        return .unavailable
      }
      return .current(note)
    } catch {
      return .failed
    }
  }

  /// Send the note's full item list. Matches what the app's own edit path
  /// sends, so the server sees an ordinary content patch.
  static func pushItems(noteId: String, items: [[String: Any]]) async -> Bool {
    guard let session = SharedStore.session() else { return false }
    let base = session.baseUrl.hasSuffix("/")
      ? String(session.baseUrl.dropLast())
      : session.baseUrl
    guard let url = URL(string: "\(base)/api/notes/\(noteId)") else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "PATCH"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
    guard
      let body = try? JSONSerialization.data(
        withJSONObject: ["items": items], options: [])
    else { return false }
    request.httpBody = body

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch {
      return false
    }
  }
}
