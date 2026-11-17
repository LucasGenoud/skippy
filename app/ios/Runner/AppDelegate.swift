import Flutter
import native_geofence
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    NativeGeofencePlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SkippyClipboard") {
      registerClipboard(messenger: registrar.messenger())
    }
  }

  /// Puts a PNG the app hands over on the pasteboard, for "Copy image".
  private func registerClipboard(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "skippy/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "copyImage",
        let png = call.arguments as? FlutterStandardTypedData
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIPasteboard.general.setData(png.data, forPasteboardType: "public.png")
      result(true)
    }
  }
}
