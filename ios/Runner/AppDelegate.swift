import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // The LiDAR scanner is app-local rather than a pub package, so it is
    // registered by hand. If depth scanning reports as unavailable on a
    // device that definitely has LiDAR, this line not running is the first
    // thing to check -- see LidarScanner/README-VALIDATION.md.
    if let registrar = engineBridge.pluginRegistry
      .registrar(forPlugin: "LidarScannerPlugin") {
      LidarScannerPlugin.register(with: registrar)
    }
  }
}
