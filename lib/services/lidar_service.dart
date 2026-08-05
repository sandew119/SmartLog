import 'dart:io';

/// Reports whether a LiDAR-assisted measurement flow should be offered.
///
/// This is a soft, best-effort signal only — iOS does not expose a simple
/// static "does this device have LiDAR" check to Flutter without starting an
/// actual ARKit session. `isLiDARAvailable` therefore only decides whether
/// the "Scan with LiDAR" option is shown at all (iOS, non-simulator). The
/// real safety net lives in the LiDAR measurement screen: if the ARKit
/// session itself fails to start (no LiDAR sensor, camera permission denied,
/// running in the simulator, etc.) that screen must catch the failure and
/// let the user fall back to manual entry instead of crashing.
class LiDARService {
  LiDARService._();

  static final instance = LiDARService._();

  Future<bool> isLiDARAvailable() async {
    if (!Platform.isIOS) {
      return false;
    }

    // iOS Simulator builds never have a real camera/LiDAR sensor.
    final bool isSimulator = Platform.environment.containsKey(
      "SIMULATOR_DEVICE_NAME",
    );

    return !isSimulator;
  }
}
