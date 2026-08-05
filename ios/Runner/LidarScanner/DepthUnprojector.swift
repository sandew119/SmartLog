import ARKit
import CoreVideo
import Foundation
import simd

/// Turns an ARKit depth map into world-space 3D points.
///
/// IMPORTANT: this file contains the single most failure-prone piece of the
/// whole LiDAR feature -- the camera convention and the intrinsics scaling.
/// Get either wrong and the points still *look* plausible (right count,
/// finite values, roughly the right magnitude) while being systematically
/// warped, which would silently corrupt every measurement.
///
/// That is why `unproject` below is a pure function over plain arrays: it
/// can be unit-tested on a Mac with no device (see
/// `ios/RunnerTests/DepthUnprojectorTests.swift`), and validated against a
/// flat wall as the very first on-device milestone. Do not trust any log
/// measurement until the flat-wall check passes -- see README-VALIDATION.md.
enum DepthUnprojector {

    /// Minimum ARKit confidence to accept. `.medium` (1) drops the worst
    /// returns -- typically edges, dark wet bark, and sunlit surfaces --
    /// without discarding most of a normal scan.
    static let defaultMinConfidence: UInt8 = 1

    /// Beyond this range iPhone LiDAR degrades badly, so points further out
    /// are noise rather than signal.
    static let defaultMaxDepthMetres: Float = 5.0

    /// Unprojects a depth map into world space.
    ///
    /// - Parameters:
    ///   - depths: row-major depth values in METRES, `width * height` long.
    ///     ARKit reports distance along the camera's viewing axis, not
    ///     radial distance from the lens.
    ///   - confidences: matching `ARConfidenceLevel` raw values, or nil to
    ///     accept every pixel.
    ///   - width/height: depth map dimensions (typically 256x192).
    ///   - fx/fy/cx/cy: intrinsics of the FULL captured image, not of the
    ///     depth map. They are rescaled below -- forgetting this is the
    ///     classic bug, and it yields a plausible-looking but wrong scale.
    ///   - imageWidth/imageHeight: dimensions those intrinsics belong to.
    ///   - cameraTransform: ARCamera.transform (camera space -> world).
    ///   - stride: sample every Nth pixel; 1 keeps all ~49k points.
    static func unproject(
        depths: [Float],
        confidences: [UInt8]?,
        width: Int,
        height: Int,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        imageWidth: Int,
        imageHeight: Int,
        cameraTransform: simd_float4x4,
        minConfidence: UInt8 = defaultMinConfidence,
        maxDepthMetres: Float = defaultMaxDepthMetres,
        stride: Int = 1
    ) -> [simd_float3] {

        guard width > 0, height > 0,
              depths.count >= width * height,
              imageWidth > 0, imageHeight > 0,
              fx > 0, fy > 0,
              stride >= 1
        else { return [] }

        // Intrinsics describe the full-resolution image; the depth map is a
        // downscaled version of the same view, so every intrinsic scales by
        // the same ratio.
        let scaleX = Float(width) / Float(imageWidth)
        let scaleY = Float(height) / Float(imageHeight)

        let fxDepth = fx * scaleX
        let fyDepth = fy * scaleY
        let cxDepth = cx * scaleX
        let cyDepth = cy * scaleY

        guard fxDepth > 0, fyDepth > 0 else { return [] }

        var points: [simd_float3] = []
        points.reserveCapacity((width / stride) * (height / stride))

        for row in Swift.stride(from: 0, to: height, by: stride) {
            for col in Swift.stride(from: 0, to: width, by: stride) {
                let index = row * width + col

                let depth = depths[index]
                guard depth.isFinite, depth > 0, depth <= maxDepthMetres
                else { continue }

                if let confidences, index < confidences.count,
                   confidences[index] < minConfidence {
                    continue
                }

                // Pinhole model. Image coordinates run x-right / y-DOWN,
                // while ARKit camera space is x-right / y-UP / -z-FORWARD,
                // hence the two sign flips below. These signs are exactly
                // what the flat-wall validation exists to confirm.
                let xCamera = (Float(col) - cxDepth) * depth / fxDepth
                let yCamera = (Float(row) - cyDepth) * depth / fyDepth

                let local = simd_float4(xCamera, -yCamera, -depth, 1)
                let world = cameraTransform * local

                points.append(simd_float3(world.x, world.y, world.z))
            }
        }

        return points
    }

    /// Reads a depth `CVPixelBuffer` into a plain `[Float]`.
    ///
    /// Thin wrapper on purpose -- all the maths lives in the pure function
    /// above so it stays testable without a camera.
    static func floats(from buffer: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(buffer)
                == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var values = [Float](repeating: 0, count: width * height)

        // Copy row by row: the buffer is padded to its stride, so a single
        // flat memcpy would interleave garbage from the padding.
        for row in 0..<height {
            let rowStart = base.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: Float.self)
            for col in 0..<width {
                values[row * width + col] = rowStart[col]
            }
        }

        return values
    }

    /// Reads a confidence `CVPixelBuffer` (one byte per pixel).
    static func confidences(from buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var values = [UInt8](repeating: 0, count: width * height)

        for row in 0..<height {
            let rowStart = base.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                values[row * width + col] = rowStart[col]
            }
        }

        return values
    }
}
