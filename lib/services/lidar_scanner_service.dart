import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

/// A depth capture returned by the native scanner.
class PointCloudCapture {
  /// World-space points, in metres.
  final List<Vector3> points;

  /// Where the user tapped, in world space, in tap order.
  final List<Vector3> taps;

  /// ARKit tracking quality at capture time: "normal", "limited",
  /// "notAvailable".
  final String trackingState;

  const PointCloudCapture({
    required this.points,
    required this.taps,
    required this.trackingState,
  });

  bool get isTrackingReliable => trackingState == "normal";
}

/// Dart side of the native LiDAR module.
///
/// Every method degrades to a safe value rather than throwing. That matters
/// more than usual here: the native side is written without a device to
/// test on, so this layer assumes it may be missing, may return the wrong
/// shape, or may fail outright -- and none of that is allowed to crash the
/// app or block the user, who can always measure by hand instead.
class LidarScannerService {
  LidarScannerService._();

  static final LidarScannerService instance = LidarScannerService._();

  static const platformViewType = "smartlog/lidar_scan_view";

  static const MethodChannel _channel =
      MethodChannel("smartlog/lidar_scanner");

  Future<bool> isSupported() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>("isSupported");
      return result ?? false;
    } on MissingPluginException {
      // Native module not present in this build.
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Why depth scanning is unavailable, if the native side can say.
  Future<String?> unavailableReason() async {
    if (!Platform.isIOS) {
      return "Depth scanning is only available on iPhone and iPad.";
    }

    try {
      return await _channel.invokeMethod<String>("unavailableReason");
    } catch (_) {
      return null;
    }
  }

  /// Clears the tap markers on a live scan view.
  Future<void> clearTaps(int viewId) async {
    try {
      await MethodChannel("smartlog/lidar_scanner/view_$viewId")
          .invokeMethod<void>("clearTaps");
    } catch (_) {}
  }

  /// Stops folding new frames into the accumulated cloud.
  ///
  /// Called before capturing so the cloud cannot shift underneath the
  /// measurement while it is being read.
  Future<void> stopSweep(int viewId) async {
    try {
      await MethodChannel("smartlog/lidar_scanner/view_$viewId")
          .invokeMethod<void>("stopSweep");
    } catch (_) {}
  }

  /// Captures the current depth frame as a world-space point cloud.
  ///
  /// Returns null on any failure -- caller falls back to manual entry.
  Future<PointCloudCapture?> capture(int viewId) async {
    try {
      final raw = await MethodChannel("smartlog/lidar_scanner/view_$viewId")
          .invokeMapMethod<String, dynamic>("capture");

      return parseCapture(raw);
    } catch (_) {
      return null;
    }
  }

  /// Decodes a capture payload.
  ///
  /// Exposed separately so the parsing -- the part most likely to disagree
  /// with what the untested native side actually sends -- can be tested
  /// directly against malformed input.
  static PointCloudCapture? parseCapture(Map<String, dynamic>? raw) {
    if (raw == null) return null;

    final points = _toVectors(raw["points"]);
    if (points == null || points.isEmpty) return null;

    // `as String?` would throw on a mistyped value; the native side is
    // unverified, so read it defensively.
    final tracking = raw["trackingState"];

    return PointCloudCapture(
      points: points,
      taps: _toVectors(raw["taps"]) ?? const [],
      trackingState: tracking is String ? tracking : "unknown",
    );
  }

  /// Converts a flat xyz Float32 buffer into vectors, discarding anything
  /// non-finite.
  static List<Vector3>? _toVectors(Object? value) {
    if (value == null) return null;

    final Float32List floats;

    if (value is Float32List) {
      floats = value;
    } else if (value is List) {
      // Some channel paths deliver a plain List<double>.
      try {
        floats = Float32List.fromList(
          value.whereType<num>().map((n) => n.toDouble()).toList(),
        );
      } catch (_) {
        return null;
      }
    } else {
      return null;
    }

    final result = <Vector3>[];

    for (var i = 0; i + 2 < floats.length; i += 3) {
      final x = floats[i];
      final y = floats[i + 1];
      final z = floats[i + 2];

      // A single NaN would poison every downstream fit, so drop bad points
      // rather than trusting the sender.
      if (!x.isFinite || !y.isFinite || !z.isFinite) continue;

      result.add(Vector3(x, y, z));
    }

    return result;
  }
}
