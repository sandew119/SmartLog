import ARKit
import Flutter
import Foundation
import SceneKit
import UIKit
import simd

/// Hosts our own `ARSCNView` as a Flutter platform view.
///
/// We cannot reuse `arkit_plugin` for this: an `ARSCNView` owns its
/// `ARSession`, and starting a second session for `.sceneDepth` pauses the
/// first -- you get a frozen preview and a dead session. So this screen
/// runs its own session, and must never be shown at the same time as the
/// Optimal Cutting AR screen.
class LidarScanView: NSObject, FlutterPlatformView, ARSessionDelegate {

    private let sceneView: ARSCNView
    private let channel: FlutterMethodChannel

    /// Most recent frame, kept so a capture can be taken on demand rather
    /// than streaming every frame across the channel.
    private var latestFrame: ARFrame?

    /// Markers the user has tapped, in world space.
    private var tappedPoints: [simd_float3] = []

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
        sceneView = ARSCNView(frame: frame)
        channel = FlutterMethodChannel(
            name: "smartlog/lidar_scanner/view_\(viewId)",
            binaryMessenger: messenger
        )

        super.init()

        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let tap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap(_:))
        )
        sceneView.addGestureRecognizer(tap)

        startSession()
    }

    func view() -> UIView { sceneView }

    // MARK: - Session

    private func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity

        if #available(iOS 14.0, *) {
            // Prefer smoothed depth: it is temporally filtered, which cuts
            // the frame-to-frame flicker that would otherwise show up as
            // noise in the circle fits.
            if ARWorldTrackingConfiguration
                .supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration
                .supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
        }

        // Deliberately NOT enabling sceneReconstruction: ARKit's mesh is
        // smoothed and decimated, which is worse for sub-centimetre circle
        // fitting than the raw depth map, and it costs CPU and battery.

        sceneView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Surfaced to Dart so the UI can offer manual entry instead of
        // leaving the user staring at a frozen preview.
        channel.invokeMethod(
            "sessionFailed",
            arguments: ["message": error.localizedDescription]
        )
    }

    func sessionWasInterrupted(_ session: ARSession) {
        channel.invokeMethod("sessionInterrupted", arguments: nil)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        startSession()
        channel.invokeMethod("sessionResumed", arguments: nil)
    }

    // MARK: - Tapping

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: sceneView)

        guard let point = worldPoint(at: location) else {
            channel.invokeMethod(
                "tapMissed",
                arguments: [
                    "message": "No surface found there. Move closer to the log."
                ]
            )
            return
        }

        tappedPoints.append(point)
        addMarker(at: point)

        channel.invokeMethod(
            "tapped",
            arguments: [
                "x": Double(point.x),
                "y": Double(point.y),
                "z": Double(point.z),
                "index": tappedPoints.count - 1,
            ]
        )
    }

    /// Resolves a screen point to a world position using the depth-backed
    /// raycast, falling back to estimated planes.
    private func worldPoint(at location: CGPoint) -> simd_float3? {
        if #available(iOS 14.0, *) {
            // .estimatedPlane + .any gives a result on an irregular log
            // surface, where existing-plane raycasts would find nothing.
            if let query = sceneView.raycastQuery(
                from: location,
                allowing: .estimatedPlane,
                alignment: .any
            ), let hit = sceneView.session.raycast(query).first {
                let t = hit.worldTransform.columns.3
                return simd_float3(t.x, t.y, t.z)
            }
        }

        let results = sceneView.hitTest(
            location,
            types: [.featurePoint, .estimatedHorizontalPlane]
        )

        guard let hit = results.first else { return nil }

        let t = hit.worldTransform.columns.3
        return simd_float3(t.x, t.y, t.z)
    }

    private func addMarker(at position: simd_float3) {
        let sphere = SCNSphere(radius: 0.01)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen
        material.lightingModel = .constant
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.simdPosition = position
        node.name = "marker"

        sceneView.scene.rootNode.addChildNode(node)
    }

    private func clearMarkers() {
        sceneView.scene.rootNode.childNodes
            .filter { $0.name == "marker" }
            .forEach { $0.removeFromParentNode() }

        tappedPoints.removeAll()
    }

    // MARK: - Channel

    private func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "clearTaps":
            clearMarkers()
            result(nil)

        case "capture":
            capture(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Grabs the current depth frame and returns a world-space point cloud.
    ///
    /// The whole cloud crosses the channel once per measurement (~3-8k
    /// points after filtering, tens of KB) rather than streaming frames.
    /// All geometry -- circle fitting, axis refinement, quality gates --
    /// happens in Dart, where it can be tested without a device.
    private func capture(result: @escaping FlutterResult) {
        guard let frame = latestFrame else {
            result(
                FlutterError(
                    code: "NO_FRAME",
                    message: "The camera has not produced a frame yet.",
                    details: nil
                )
            )
            return
        }

        guard #available(iOS 14.0, *) else {
            result(
                FlutterError(
                    code: "UNSUPPORTED",
                    message: "Depth capture requires iOS 14 or later.",
                    details: nil
                )
            )
            return
        }

        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth

        guard let depthData,
              let depths = DepthUnprojector.floats(from: depthData.depthMap)
        else {
            result(
                FlutterError(
                    code: "NO_DEPTH",
                    message: "No depth data. This device may not have LiDAR.",
                    details: nil
                )
            )
            return
        }

        let confidences = depthData.confidenceMap
            .flatMap { DepthUnprojector.confidences(from: $0) }

        let width = CVPixelBufferGetWidth(depthData.depthMap)
        let height = CVPixelBufferGetHeight(depthData.depthMap)

        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution

        let points = DepthUnprojector.unproject(
            depths: depths,
            confidences: confidences,
            width: width,
            height: height,
            fx: intrinsics[0][0],
            fy: intrinsics[1][1],
            cx: intrinsics[2][0],
            cy: intrinsics[2][1],
            imageWidth: Int(imageResolution.width),
            imageHeight: Int(imageResolution.height),
            cameraTransform: frame.camera.transform
        )

        // Flatten to xyz triples: a typed buffer crosses the channel far
        // more cheaply than a list of dictionaries.
        var flat = [Float32]()
        flat.reserveCapacity(points.count * 3)
        for p in points {
            flat.append(p.x)
            flat.append(p.y)
            flat.append(p.z)
        }

        var taps = [Float32]()
        for p in tappedPoints {
            taps.append(p.x)
            taps.append(p.y)
            taps.append(p.z)
        }

        result([
            "points": FlutterStandardTypedData(float32: Data(
                bytes: flat, count: flat.count * MemoryLayout<Float32>.size
            )),
            "taps": FlutterStandardTypedData(float32: Data(
                bytes: taps, count: taps.count * MemoryLayout<Float32>.size
            )),
            "pointCount": points.count,
            "depthWidth": width,
            "depthHeight": height,
            "trackingState": trackingStateName(frame.camera.trackingState),
        ])
    }

    private func trackingStateName(
        _ state: ARCamera.TrackingState
    ) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        }
    }

    deinit {
        sceneView.session.pause()
    }
}

/// Factory registered with Flutter so `UiKitView` can create the scan view.
class LidarScanViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        LidarScanView(frame: frame, viewId: viewId, messenger: messenger)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
