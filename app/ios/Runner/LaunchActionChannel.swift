import Flutter
import Foundation

/// Carries links from App Intents to Dart (`app_intent_launches.dart`).
///
/// An intent can run before Dart is listening, on a cold start most of all, so
/// links wait here until Dart calls `ready`, which takes the backlog. Later
/// links go straight across. Main thread only, like the intents and the
/// channel that call it.
final class LaunchActionChannel {
  static let shared = LaunchActionChannel()

  private static let name = "skippy/launch_actions"
  private static let readyMethod = "ready"
  private static let openMethod = "open"

  private var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var ready = false

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == Self.readyMethod else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.ready = true
      result(self.pending)
      self.pending = []
    }
    self.channel = channel
  }

  func open(_ url: URL) {
    guard ready, let channel else {
      pending.append(url.absoluteString)
      return
    }
    channel.invokeMethod(Self.openMethod, arguments: url.absoluteString)
  }
}
