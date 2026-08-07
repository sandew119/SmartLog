import 'dart:io';

import 'lidar_scanner_service.dart';

/// Device capability checks for the two different AR features in this app.
///
/// These are deliberately separate because they are NOT the same question:
///
/// - [isARAvailable] gates the Optimal Cutting flow, which measures from
///   ARKit's sparse feature points. That works on any ARKit-capable iPhone,
///   with or without a LiDAR sensor.
/// - [isDepthScanningAvailable] gates the log scanner, which needs the real
///   rear LiDAR depth stream (`sceneDepth`) and therefore a Pro-class
///   device.
///
/// Collapsing them into one check would silently remove a working feature
/// from every non-LiDAR iPhone.
class LiDARService {
  LiDARService._();

  static final instance = LiDARService._();

  bool? _cachedDepthSupport;

  /// Whether ARKit feature-point tracking is plausible on this device.
  ///
  /// A heuristic, not a real capability query: iOS, and not the simulator.
  /// It only decides whether to *offer* an AR option; the AR screens
  /// themselves must still degrade gracefully if a session fails to start.
  Future<bool> isARAvailable() async {
    if (!Platform.isIOS) return false;

    // iOS Simulator builds never have a real camera or depth sensor.
    final bool isSimulator = Platform.environment.containsKey(
      "SIMULATOR_DEVICE_NAME",
    );

    return !isSimulator;
  }

  /// Whether this device can supply a real LiDAR depth stream.
  ///
  /// Will be answered by the native module, which queries
  /// `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`.
  /// Until that module is wired in -- and on any platform, or any failure
  /// -- this is false, which routes the user to manual measurement rather
  /// than to a screen that cannot work.
  Future<bool> isDepthScanningAvailable() async {
    final cached = _cachedDepthSupport;
    if (cached != null) return cached;

    bool supported = false;

    if (Platform.isIOS) {
      try {
        supported = await LidarScannerService.instance.isSupported();
      } catch (_) {
        // Native module missing or misbehaving -- fall back to manual
        // measurement rather than showing a screen that cannot work.
        supported = false;
      }
    }

    _cachedDepthSupport = supported;
    return supported;
  }

  /// Test-only: clears the cached capability answer.
  void resetCacheForTesting() {
    _cachedDepthSupport = null;
  }
}
