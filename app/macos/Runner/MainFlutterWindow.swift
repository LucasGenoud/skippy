import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Below this the sidebar and a note column stop fitting side by side and the
  /// layout switches to its narrow, phone-shaped arrangement, which still
  /// works. The size the window first opens at lives in MainMenu.xib.
  private static let minimumSize = NSSize(width: 480, height: 540)
  private static let frameName = "SkippyMainWindow"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Assigning the content view controller shrinks the window to the Flutter
    // view, which has no size until the engine runs, so the nib's frame is
    // captured first and put back.
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = MainFlutterWindow.minimumSize

    // Remember the window's size across launches ourselves. macOS's own
    // restoration would otherwise do it, but it applies the saved frame about a
    // second after launch — late enough to overwrite the size set here, and it
    // replays frames recorded before this window had a sensible default.
    self.isRestorable = false
    self.setFrameUsingName(MainFlutterWindow.frameName)
    self.setFrameAutosaveName(MainFlutterWindow.frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MainFlutterWindow.registerClipboard(
      messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// Puts a PNG the app hands over on the pasteboard, for "Copy image".
  private static func registerClipboard(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "skippy/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "copyImage",
        let png = call.arguments as? FlutterStandardTypedData
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      NSPasteboard.general.clearContents()
      result(NSPasteboard.general.setData(png.data, forType: .png))
    }
  }
}
