import ARKit
import AVFoundation
import Flutter
import Foundation
import SceneKit
import UIKit
import simd

/// Hosts the AR camera as a Flutter platform view and streams depth frames
/// to Dart.
///
/// This is a pump and nothing else. It does no geometry: every decision
/// about where the log is, how big it is and whether the scan is good enough
/// is made in Dart (`lib/utils/face_scan.dart`, `log_girth_model.dart`,
/// `log_scan_session.dart`), where it is covered by tests run against
/// synthetic depth scenes. The previous version put 800 lines of geometry
/// here, on the one side of the app that can never be tested from the
/// machine it is written on, and it never worked on a device.
///
/// What it does do, and why each matters on a real phone:
///
/// - Every message to Dart is sent on the main thread. Flutter requires it;
///   the previous version sent from the ARKit queue, which Flutter rejects.
/// - A frame is sent only once Dart has finished with the last one. If Dart
///   falls behind, frames are dropped here rather than queued up in the
///   channel, so the scan is always working on what the camera sees now.
/// - No `ARFrame` is ever held on to. ARKit stops delivering frames to a
///   delegate that retains them, which looks exactly like a frozen camera.
///
/// We cannot reuse `arkit_plugin` for this: an `ARSCNView` owns its
/// `ARSession`, and a second session for `.sceneDepth` pauses the first. So
/// this screen runs its own, and must never be open at the same time as the
/// Optimal Cutting AR screen.
class LidarScanView: NSObject, FlutterPlatformView, ARSessionDelegate {

    private let sceneView: ARSCNView
    private let channel: FlutterMethodChannel

    /// Frame callbacks arrive here rather than on the main thread, so copying
    /// the depth map out never stutters the camera preview.
    private let sessionQueue = DispatchQueue(
        label: "smartlog.lidar.session",
        qos: .userInitiated
    )

    /// Guards everything below, which the session queue and the main thread
    /// both touch.
    private let stateLock = NSLock()

    private var isStreaming = false
    private var awaitingAck = false
    private var lastSentTime: TimeInterval = 0

    /// When the last frame went out. If Dart never answers -- an exception on
    /// its side, a hot reload -- streaming resumes after this long rather
    /// than stalling for good.
    private var sentAt: TimeInterval = 0
    private let ackTimeout: TimeInterval = 1.0

    /// Seconds between frames. Ten a second is plenty to feel live; the
    /// backpressure above means the real rate is whatever Dart can keep up
    /// with, never more.
    private var frameInterval: TimeInterval = 0.1

    /// Every Nth depth pixel. 2 halves the 256x192 map to 128x96, which is
    /// ~12k samples a frame: ample for a log end at arm's length, and small
    /// enough to cross the channel ten times a second. Restricted to exact
    /// divisors of the map so the decimated grid keeps the map's exact
    /// proportions -- Dart rescales the intrinsics on that assumption.
    private var decimation = 2

    /// Speaks the milestones -- "Face scan complete", "Length complete" --
    /// for someone whose eyes are on the log, not the screen. Held for the
    /// life of the view: a synthesizer released mid-sentence stops talking.
    private let speech = AVSpeechSynthesizer()

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
        sceneView = ARSCNView(frame: frame)
        channel = FlutterMethodChannel(
            name: "smartlog/lidar_scanner/view_\(viewId)",
            binaryMessenger: messenger
        )

        super.init()

        sceneView.session.delegate = self
        sceneView.session.delegateQueue = sessionQueue
        sceneView.automaticallyUpdatesLighting = false

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        startSession()
    }

    func view() -> UIView { sceneView }

    // MARK: - Session

    private func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity

        if #available(iOS 14.0, *) {
            // Smoothed depth is filtered over time, which takes the
            // frame-to-frame flicker out of the edge of a log end.
            if ARWorldTrackingConfiguration
                .supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration
                .supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
        }

        sceneView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp

        stateLock.lock()
        let due = isStreaming
            && now - lastSentTime >= frameInterval
            && (!awaitingAck || now - sentAt > ackTimeout)
        let stride = decimation
        stateLock.unlock()

        guard due else { return }

        // Everything needed is copied out here; the frame itself is released
        // as soon as this method returns.
        guard let payload = LidarScanView.payload(from: frame, stride: stride)
        else { return }

        stateLock.lock()
        lastSentTime = now
        sentAt = now
        awaitingAck = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("frame", arguments: payload)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription

        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod(
                "sessionFailed",
                arguments: ["message": message]
            )
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod("sessionInterrupted", arguments: nil)
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // World tracking cannot be trusted across an interruption: the
            // phone may have moved anywhere. Dart restarts the step in
            // progress when it hears this.
            self.startSession()
            self.channel.invokeMethod("sessionResumed", arguments: nil)
        }
    }

    // MARK: - Frame payload

    /// Everything Dart needs from one frame, as plain channel types.
    private static func payload(
        from frame: ARFrame,
        stride: Int
    ) -> [String: Any]? {
        guard #available(iOS 14.0, *) else { return nil }

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        else { return nil }

        guard let grid = decimate(
            depth: depthData.depthMap,
            confidence: depthData.confidenceMap,
            stride: stride
        ) else { return nil }

        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution

        // Column-major, as simd stores it and as Dart's Matrix4 reads it --
        // the buffer crosses with no transpose on either side.
        let t = frame.camera.transform
        let transform: [Float32] = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]

        var payload: [String: Any] = [
            "width": grid.width,
            "height": grid.height,
            "depths": typedFloats(grid.depths),
            // Intrinsics of the full captured image, exactly as ARKit reports
            // them. Dart rescales them to the depth grid, where that rescale
            // is tested.
            "imageWidth": Int(resolution.width),
            "imageHeight": Int(resolution.height),
            "fx": Double(intrinsics[0][0]),
            "fy": Double(intrinsics[1][1]),
            "cx": Double(intrinsics[2][0]),
            "cy": Double(intrinsics[2][1]),
            "transform": typedFloats(transform),
            "tracking": trackingName(frame.camera.trackingState),
            "trackingReason": trackingReason(frame.camera.trackingState),
            "timestamp": frame.timestamp,
        ]

        if let confidence = grid.confidence {
            payload["confidence"] = FlutterStandardTypedData(
                bytes: Data(confidence)
            )
        }

        return payload
    }

    /// Copies every Nth pixel of the depth map, and the confidence map
    /// alongside it, in a single pass.
    ///
    /// Row by row through the buffer's own stride: the rows are padded, so a
    /// flat copy would interleave padding bytes into the depths.
    private static func decimate(
        depth: CVPixelBuffer,
        confidence: CVPixelBuffer?,
        stride: Int
    ) -> (depths: [Float32], confidence: [UInt8]?, width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(depth)
                == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(depth)
        else { return nil }

        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)

        let step = max(1, stride)
        let outWidth = width / step
        let outHeight = height / step

        guard outWidth >= 8, outHeight >= 8 else { return nil }

        var depths = [Float32](repeating: 0, count: outWidth * outHeight)

        for row in 0..<outHeight {
            let source = base.advanced(by: row * step * rowBytes)
                .assumingMemoryBound(to: Float32.self)

            for col in 0..<outWidth {
                depths[row * outWidth + col] = source[col * step]
            }
        }

        var confidences: [UInt8]? = nil

        if let confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }

            if CVPixelBufferGetWidth(confidence) == width,
               CVPixelBufferGetHeight(confidence) == height,
               let confidenceBase = CVPixelBufferGetBaseAddress(confidence) {
                let confidenceRowBytes =
                    CVPixelBufferGetBytesPerRow(confidence)

                var values = [UInt8](
                    repeating: 0, count: outWidth * outHeight
                )

                for row in 0..<outHeight {
                    let source = confidenceBase
                        .advanced(by: row * step * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)

                    for col in 0..<outWidth {
                        values[row * outWidth + col] = source[col * step]
                    }
                }

                confidences = values
            }
        }

        return (depths, confidences, outWidth, outHeight)
    }

    private static func typedFloats(
        _ values: [Float32]
    ) -> FlutterStandardTypedData {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return FlutterStandardTypedData(float32: data)
    }

    private static func trackingName(
        _ state: ARCamera.TrackingState
    ) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        }
    }

    /// Why tracking is limited, so Dart can say "move slower" rather than a
    /// generic "hold on".
    private static func trackingReason(
        _ state: ARCamera.TrackingState
    ) -> String {
        guard case .limited(let reason) = state else { return "" }

        switch reason {
        case .initializing: return "initializing"
        case .excessiveMotion: return "excessiveMotion"
        case .insufficientFeatures: return "insufficientFeatures"
        case .relocalizing: return "relocalizing"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Markers

    /// Draws a disc on a log end the scan has locked onto.
    ///
    /// The user's proof that the app found the right thing. Walking to the
    /// far end they can look back and see it still sitting on the end they
    /// scanned; if it is floating in the air, they know before the number
    /// comes out wrong rather than after.
    private func showMarker(
        id: String,
        position: simd_float3,
        normal: simd_float3,
        radius: Float
    ) {
        let name = "marker:\(id)"

        sceneView.scene.rootNode.childNodes
            .filter { $0.name == name }
            .forEach { $0.removeFromParentNode() }

        let disc = SCNCylinder(radius: CGFloat(radius), height: 0.004)
        disc.radialSegmentCount = 48

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen
            .withAlphaComponent(0.45)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        disc.materials = [material]

        let node = SCNNode(geometry: disc)
        node.name = name
        node.simdPosition = position

        // SceneKit builds a cylinder up its own Y axis; turn it onto the
        // face's normal so the disc lies flat on the end.
        let length = simd_length(normal)
        if length > 1e-6 {
            node.simdOrientation = simd_quatf(
                from: simd_float3(0, 1, 0),
                to: normal / length
            )
        }

        sceneView.scene.rootNode.addChildNode(node)
    }

    private func clearMarkers() {
        sceneView.scene.rootNode.childNodes
            .filter {
                $0.name?.hasPrefix("marker:") == true
                    || $0.name?.hasPrefix("outline:") == true
            }
            .forEach { $0.removeFromParentNode() }
    }

    // MARK: - Outlines

    /// Draws a ribbon on the log: the outline the scanner is measuring, in the
    /// place it is measuring it.
    ///
    /// Dart builds the ribbon -- a closed strip of triangles, two vertices to
    /// each point of the outline -- and this only hands it to SceneKit. It is
    /// anchored in the world, so it stays on the end as the phone moves, and
    /// it is what tells the user, before any number appears, that the app has
    /// found the right thing and is working on it.
    private func showOutline(id: String, vertices: [Float], color: UIColor) {
        let name = "outline:\(id)"

        sceneView.scene.rootNode.childNodes
            .filter { $0.name == name }
            .forEach { $0.removeFromParentNode() }

        let count = vertices.count / 3
        guard count >= 4 else { return }

        var points: [SCNVector3] = []
        points.reserveCapacity(count)

        for i in 0..<count {
            points.append(
                SCNVector3(vertices[3 * i], vertices[3 * i + 1], vertices[3 * i + 2])
            )
        }

        let source = SCNGeometrySource(vertices: points)

        let indices: [Int32] = (0..<Int32(count)).map { $0 }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangleStrip,
            primitiveCount: count - 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = name
        node.renderingOrder = 100

        sceneView.scene.rootNode.addChildNode(node)
    }

    private func clearOutline(id: String) {
        let name = "outline:\(id)"

        sceneView.scene.rootNode.childNodes
            .filter { $0.name == name }
            .forEach { $0.removeFromParentNode() }
    }

    // MARK: - Channel

    /// Flutter calls this on the main thread.
    private func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "start":
            stateLock.lock()
            if let requested = LidarScanView.int(args?["decimation"]),
               [1, 2, 4].contains(requested) {
                decimation = requested
            }
            if let ms = LidarScanView.int(args?["intervalMs"]), ms >= 30 {
                frameInterval = Double(ms) / 1000
            }
            isStreaming = true
            awaitingAck = false
            lastSentTime = 0
            stateLock.unlock()

            // A scan is a minute of holding the phone still; the screen
            // dimming halfway through reads as the app having frozen.
            UIApplication.shared.isIdleTimerDisabled = true
            result(nil)

        case "stop":
            stateLock.lock()
            isStreaming = false
            awaitingAck = false
            stateLock.unlock()

            UIApplication.shared.isIdleTimerDisabled = false
            result(nil)

        case "ack":
            stateLock.lock()
            awaitingAck = false
            stateLock.unlock()
            result(nil)

        case "restartTracking":
            clearMarkers()
            startSession()
            result(nil)

        case "showMarker":
            guard let id = args?["id"] as? String,
                  let x = LidarScanView.float(args?["x"]),
                  let y = LidarScanView.float(args?["y"]),
                  let z = LidarScanView.float(args?["z"]),
                  let nx = LidarScanView.float(args?["nx"]),
                  let ny = LidarScanView.float(args?["ny"]),
                  let nz = LidarScanView.float(args?["nz"]),
                  let radius = LidarScanView.float(args?["radius"]),
                  radius > 0
            else {
                result(nil)
                return
            }

            showMarker(
                id: id,
                position: simd_float3(x, y, z),
                normal: simd_float3(nx, ny, nz),
                radius: radius
            )
            result(nil)

        case "clearMarkers":
            clearMarkers()
            result(nil)

        case "showOutline":
            guard let id = args?["id"] as? String,
                  let vertices = LidarScanView.floats(args?["vertices"]),
                  let red = LidarScanView.float(args?["r"]),
                  let green = LidarScanView.float(args?["g"]),
                  let blue = LidarScanView.float(args?["b"]),
                  let alpha = LidarScanView.float(args?["a"])
            else {
                result(nil)
                return
            }

            showOutline(
                id: id,
                vertices: vertices,
                color: UIColor(
                    red: CGFloat(red),
                    green: CGFloat(green),
                    blue: CGFloat(blue),
                    alpha: CGFloat(alpha)
                )
            )
            result(nil)

        case "clearOutline":
            if let id = args?["id"] as? String {
                clearOutline(id: id)
            }
            result(nil)

        case "viewToImage":
            // Where a tap on the screen lands in the camera image -- and so in
            // the depth map, which is the same picture. ARKit knows how the
            // image is rotated and cropped to fill the screen; this asks it,
            // instead of Dart guessing at the orientation.
            guard let frame = sceneView.session.currentFrame,
                  let x = LidarScanView.float(args?["x"]),
                  let y = LidarScanView.float(args?["y"])
            else {
                result(nil)
                return
            }

            let size = sceneView.bounds.size
            guard size.width > 0, size.height > 0 else {
                result(nil)
                return
            }

            let orientation = sceneView.window?.windowScene?.interfaceOrientation
                ?? .portrait

            let toScreen = frame.displayTransform(
                for: orientation,
                viewportSize: size
            )

            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                .applying(toScreen.inverted())

            result(["u": Double(point.x), "v": Double(point.y)])

        case "speak":
            if let text = args?["text"] as? String, !text.isEmpty {
                // A new milestone replaces an old one rather than queueing
                // behind it; a stale "walk to the other end" spoken after the
                // scan finished would be worse than silence.
                if speech.isSpeaking {
                    speech.stopSpeaking(at: .immediate)
                }
                speech.speak(AVSpeechUtterance(string: text))
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// A Float32 buffer from Dart, as an array.
    private static func floats(_ value: Any?) -> [Float]? {
        guard let typed = value as? FlutterStandardTypedData else { return nil }

        let count = typed.data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }

        return typed.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    private static func float(_ value: Any?) -> Float? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.floatValue
        return result.isFinite ? result : nil
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    deinit {
        channel.setMethodCallHandler(nil)
        sceneView.session.pause()

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
