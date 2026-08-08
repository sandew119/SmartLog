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

    /// Depth merged across the whole sweep. See `DepthAccumulator` for why a
    /// single frame cannot measure a log.
    private let accumulator = DepthAccumulator()

    /// Whether frames are currently being folded in. Accumulation starts
    /// when the user picks a log, not before, so the ground they walked
    /// over on the way does not end up in the cloud.
    private var isAccumulating = false

    /// Wall-clock time of the last frame folded in.
    private var lastAccumulationTime: TimeInterval = 0

    /// Fold in about ten frames a second. Unprojecting every frame at 60 Hz
    /// costs far more battery and CPU than it adds coverage, since
    /// consecutive frames from a slowly moving phone are nearly identical.
    private let accumulationInterval: TimeInterval = 0.1

    /// Sample every Nth depth pixel while sweeping. The full map is ~49k
    /// points per frame; at ten frames a second that is more than the voxel
    /// grid can usefully absorb, and it drops frames on older devices.
    private let accumulationStride = 2

    /// Throttles telemetry back to Dart so the UI updates smoothly without
    /// flooding the channel.
    private var lastStatsTime: TimeInterval = 0

    /// Frame callbacks run here rather than on the main thread.
    ///
    /// Unprojecting a depth map is tens of thousands of points of work, ten
    /// times a second. ARKit delivers frames on the main queue by default,
    /// so leaving it there would stutter the very camera preview the user is
    /// aiming with.
    private let sessionQueue = DispatchQueue(
        label: "smartlog.lidar.session",
        qos: .userInitiated
    )

    /// Guards state now touched from both the session queue and the channel.
    private let stateLock = NSLock()

    /// Shows the user what has actually been captured so far.
    private let capturedNode = SCNNode()

    private var lastOverlayTime: TimeInterval = 0

    /// Redrawing the overlay is the most expensive thing on screen, and it
    /// only has to feel live, not be smooth.
    private let overlayInterval: TimeInterval = 0.5

    /// Points drawn in the overlay. Enough to read as a solid surface,
    /// few enough to rebuild twice a second without dropping frames.
    private let overlayPointBudget = 6000

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
        sceneView = ARSCNView(frame: frame)
        channel = FlutterMethodChannel(
            name: "smartlog/lidar_scanner/view_\(viewId)",
            binaryMessenger: messenger
        )

        super.init()

        sceneView.session.delegate = self
        sceneView.session.delegateQueue = sessionQueue
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene.rootNode.addChildNode(capturedNode)

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
        stateLock.lock()
        latestFrame = frame
        let gathering = isAccumulating
        stateLock.unlock()

        guard gathering else { return }

        // Only fold in frames the tracker is confident about. Points
        // captured while tracking is limited are placed against a drifting
        // world origin, which smears the accumulated cloud and would widen
        // every circle fit.
        if case .normal = frame.camera.trackingState {} else { return }

        let now = frame.timestamp

        if now - lastAccumulationTime >= accumulationInterval {
            lastAccumulationTime = now
            accumulate(frame: frame)
        }

        if now - lastStatsTime >= 0.25 {
            lastStatsTime = now
            reportProgress()
        }

        if now - lastOverlayTime >= overlayInterval {
            lastOverlayTime = now
            refreshOverlay()
        }
    }

    /// Draws the captured surface back over the camera feed.
    ///
    /// Without this the user taps a log and gets no confirmation of what the
    /// app actually picked up -- a mis-aimed tap stays invisible until the
    /// number comes out wrong. Seeing the trunk fill in as they walk is also
    /// what tells them which stretch they have missed.
    private func refreshOverlay() {
        stateLock.lock()
        let points = accumulator.snapshot()
        stateLock.unlock()

        guard points.count >= 8 else { return }

        // Even spacing rather than the first N, so the overlay reflects the
        // whole sweep instead of wherever gathering started.
        let step = max(1, points.count / overlayPointBudget)
        var sampled: [SCNVector3] = []
        sampled.reserveCapacity(min(points.count, overlayPointBudget))

        var index = 0
        while index < points.count {
            let p = points[index]
            sampled.append(SCNVector3(p.x, p.y, p.z))
            index += step
        }

        let source = SCNGeometrySource(vertices: sampled)

        let indices = (0..<Int32(sampled.count)).map { $0 }
        let element = SCNGeometryElement(
            indices: indices,
            primitiveType: .point
        )
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = 6

        let geometry = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        // SceneKit's graph belongs to the main thread; frames arrive on the
        // session queue.
        DispatchQueue.main.async { [weak self] in
            self?.capturedNode.geometry = geometry
        }
    }

    private func accumulate(frame: ARFrame) {
        guard #available(iOS 14.0, *) else { return }

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let depths = DepthUnprojector.floats(from: depthData.depthMap)
        else { return }

        let confidences = depthData.confidenceMap
            .flatMap { DepthUnprojector.confidences(from: $0) }

        let width = CVPixelBufferGetWidth(depthData.depthMap)
        let height = CVPixelBufferGetHeight(depthData.depthMap)

        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution

        let points = DepthUnprojector.unproject(
            depths: depths,
            confidences: confidences,
            width: width,
            height: height,
            fx: intrinsics[0][0],
            fy: intrinsics[1][1],
            cx: intrinsics[2][0],
            cy: intrinsics[2][1],
            imageWidth: Int(resolution.width),
            imageHeight: Int(resolution.height),
            cameraTransform: frame.camera.transform,
            stride: accumulationStride
        )

        stateLock.lock()
        accumulator.add(points)
        stateLock.unlock()
    }

    private func reportProgress() {
        stateLock.lock()
        let stats = accumulator.stats
        stateLock.unlock()

        channel.invokeMethod(
            "progress",
            arguments: [
                "pointCount": stats.pointCount,
                "frameCount": stats.frameCount,
                "extent": Double(stats.extent),
            ]
        )
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

        // Picking the log is the signal to start gathering. Accumulating
        // before this would fold in the ground the user walked over on the
        // way to it, and there is nothing for the user to press instead.
        stateLock.lock()
        if !isAccumulating {
            accumulator.reset()
            isAccumulating = true
            lastAccumulationTime = 0
            lastStatsTime = 0
            lastOverlayTime = 0
        }
        stateLock.unlock()

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
        capturedNode.geometry = nil

        // Starting over means starting over: a cloud gathered around the
        // previous pick must not survive into the next measurement.
        stateLock.lock()
        isAccumulating = false
        accumulator.reset()
        stateLock.unlock()
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

        case "startSweep":
            stateLock.lock()
            accumulator.reset()
            isAccumulating = true
            lastAccumulationTime = 0
            lastStatsTime = 0
            lastOverlayTime = 0
            stateLock.unlock()
            result(nil)

        case "stopSweep":
            stateLock.lock()
            isAccumulating = false
            stateLock.unlock()
            result(nil)

        case "capture":
            capture(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Returns the cloud accumulated over the sweep, in world space.
    ///
    /// The whole cloud crosses the channel once per measurement rather than
    /// streaming frames. All geometry -- segmentation, circle fitting, axis
    /// refinement, quality gates -- happens in Dart, where it can be tested
    /// without a device.
    ///
    /// Falls back to the single most recent frame when nothing was
    /// accumulated, so a user who taps and immediately finishes still gets a
    /// measurement (the quality gate will judge it) instead of an error.
    private func capture(result: @escaping FlutterResult) {
        stateLock.lock()
        let frameOrNil = latestFrame
        stateLock.unlock()

        guard let frame = frameOrNil else {
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

        stateLock.lock()
        var points = accumulator.snapshot()
        let frameCount = accumulator.frameCount
        stateLock.unlock()

        if points.isEmpty {
            guard let single = singleFramePoints(frame: frame) else {
                result(
                    FlutterError(
                        code: "NO_DEPTH",
                        message:
                            "No depth data. This device may not have LiDAR.",
                        details: nil
                    )
                )
                return
            }
            points = single
        }

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
            "frameCount": frameCount,
            "trackingState": trackingStateName(frame.camera.trackingState),
        ])
    }

    /// One frame's depth, used only when the sweep produced nothing.
    private func singleFramePoints(frame: ARFrame) -> [simd_float3]? {
        guard #available(iOS 14.0, *) else { return nil }

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let depths = DepthUnprojector.floats(from: depthData.depthMap)
        else { return nil }

        let confidences = depthData.confidenceMap
            .flatMap { DepthUnprojector.confidences(from: $0) }

        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution

        return DepthUnprojector.unproject(
            depths: depths,
            confidences: confidences,
            width: CVPixelBufferGetWidth(depthData.depthMap),
            height: CVPixelBufferGetHeight(depthData.depthMap),
            fx: intrinsics[0][0],
            fy: intrinsics[1][1],
            cx: intrinsics[2][0],
            cy: intrinsics[2][1],
            imageWidth: Int(resolution.width),
            imageHeight: Int(resolution.height),
            cameraTransform: frame.camera.transform
        )
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
