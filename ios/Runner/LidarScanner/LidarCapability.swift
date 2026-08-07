import ARKit
import Foundation

/// Answers the single question "can this device give us real LiDAR depth?".
///
/// Kept deliberately tiny and dependency-free so it can be reasoned about
/// and verified on its own before anything harder is trusted.
enum LidarCapability {

    /// True only when the rear LiDAR depth stream is actually available.
    ///
    /// This is NOT the same as "supports ARKit": every ARKit iPhone can do
    /// world tracking, but only Pro-class devices (iPhone 12 Pro and later,
    /// LiDAR iPads) publish `.sceneDepth`. Using the broader ARKit check
    /// here would promise measurement accuracy the hardware cannot deliver.
    static var supportsSceneDepth: Bool {
        guard ARWorldTrackingConfiguration.isSupported else { return false }

        if #available(iOS 14.0, *) {
            return ARWorldTrackingConfiguration
                .supportsFrameSemantics(.sceneDepth)
        }

        // sceneDepth is iOS 14+. Every LiDAR device ships iOS 14 or newer,
        // so an older OS means no depth scanning regardless of hardware.
        return false
    }

    /// True when the smoothed depth stream is available too.
    ///
    /// Smoothed depth is temporally filtered, which suppresses the frame to
    /// frame flicker that would otherwise show up as noise in the circle
    /// fits. Preferred when present.
    static var supportsSmoothedSceneDepth: Bool {
        guard ARWorldTrackingConfiguration.isSupported else { return false }

        if #available(iOS 14.0, *) {
            return ARWorldTrackingConfiguration
                .supportsFrameSemantics(.smoothedSceneDepth)
        }

        return false
    }

    /// A human-readable reason depth scanning is unavailable, for surfacing
    /// in the app rather than failing silently.
    static var unavailableReason: String? {
        if !ARWorldTrackingConfiguration.isSupported {
            return "This device does not support ARKit world tracking."
        }

        if #available(iOS 14.0, *) {
            if !ARWorldTrackingConfiguration
                .supportsFrameSemantics(.sceneDepth) {
                return "This device has no LiDAR sensor. "
                    + "Depth scanning needs an iPhone Pro (12 Pro or later) "
                    + "or a LiDAR iPad."
            }
            return nil
        }

        return "Depth scanning requires iOS 14 or later."
    }
}
