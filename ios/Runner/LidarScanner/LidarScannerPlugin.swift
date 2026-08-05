import Flutter
import Foundation

/// Registers the LiDAR scanner's channel and platform view.
///
/// Marshalling only -- no logic lives here, so there is nothing to debug
/// on-device beyond "is it wired up".
enum LidarScannerPlugin {

    static let channelName = "smartlog/lidar_scanner"
    static let viewTypeId = "smartlog/lidar_scan_view"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )

        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "isSupported":
                result(LidarCapability.supportsSceneDepth)

            case "unavailableReason":
                result(LidarCapability.unavailableReason)

            case "supportsSmoothedDepth":
                result(LidarCapability.supportsSmoothedSceneDepth)

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        registrar.register(
            LidarScanViewFactory(messenger: registrar.messenger()),
            withId: viewTypeId
        )
    }
}
