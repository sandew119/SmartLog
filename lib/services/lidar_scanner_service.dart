import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

/// A whole-log point cloud, in the shape the earlier sweep scanner captured
/// it. The live scan no longer produces one -- it streams [DepthFrame]s --
/// but [LidarMeasurementSource.measurementFrom] still measures recorded
/// clouds in this form.
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

  static const MethodChannel _channel = MethodChannel("smartlog/lidar_scanner");

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

  static MethodChannel _view(int viewId) =>
      MethodChannel("smartlog/lidar_scanner/view_$viewId");

  /// Starts depth frames flowing to Dart as `frame` calls on the view's
  /// channel. [decimation] keeps every Nth depth pixel (1, 2 or 4).
  Future<void> startStreaming(
    int viewId, {
    int decimation = 2,
    int intervalMs = 100,
  }) async {
    try {
      await _view(viewId).invokeMethod<void>("start", {
        "decimation": decimation,
        "intervalMs": intervalMs,
      });
    } catch (_) {}
  }

  Future<void> stopStreaming(int viewId) async {
    try {
      await _view(viewId).invokeMethod<void>("stop");
    } catch (_) {}
  }

  /// Tells the native side the last frame has been dealt with, so it may
  /// send the next. Without this frames are held back, never queued -- the
  /// scan always works on what the camera sees now.
  Future<void> ackFrame(int viewId) async {
    try {
      await _view(viewId).invokeMethod<void>("ack");
    } catch (_) {}
  }

  /// Draws a disc on a log end the scan has locked onto.
  Future<void> showMarker(
    int viewId, {
    required String id,
    required Vector3 position,
    required Vector3 normal,
    required double radius,
  }) async {
    try {
      await _view(viewId).invokeMethod<void>("showMarker", {
        "id": id,
        "x": position.x,
        "y": position.y,
        "z": position.z,
        "nx": normal.x,
        "ny": normal.y,
        "nz": normal.z,
        "radius": radius,
      });
    } catch (_) {}
  }

  /// Draws a ribbon on the log -- the outline being measured -- in world
  /// space, so it stays on the end as the phone moves. [vertices] is the flat
  /// `x y z` strip from `OutlineRibbon.strip`.
  Future<void> showOutline(
    int viewId, {
    required String id,
    required Float32List vertices,
    required double red,
    required double green,
    required double blue,
    double alpha = 0.9,
  }) async {
    if (vertices.length < 12) return;

    try {
      await _view(viewId).invokeMethod<void>("showOutline", {
        "id": id,
        "vertices": vertices,
        "r": red,
        "g": green,
        "b": blue,
        "a": alpha,
      });
    } catch (_) {}
  }

  Future<void> clearOutline(int viewId, String id) async {
    try {
      await _view(viewId).invokeMethod<void>("clearOutline", {"id": id});
    } catch (_) {}
  }

  /// Where a tap on the view lands in the camera image, as fractions of the
  /// image (0..1 across, 0..1 down), or null if it cannot be resolved.
  ///
  /// [x] and [y] are fractions of the view. The native side asks ARKit for the
  /// mapping, which accounts for the way the image is rotated and cropped to
  /// fill the screen; the depth map is the same picture, so the answer is a
  /// position in it too.
  Future<({double u, double v})?> viewToImage(
    int viewId, {
    required double x,
    required double y,
  }) async {
    try {
      final result = await _view(viewId).invokeMethod<Map<Object?, Object?>>(
        "viewToImage",
        {"x": x, "y": y},
      );

      final u = result?["u"];
      final v = result?["v"];

      if (u is! num || v is! num) return null;

      final du = u.toDouble();
      final dv = v.toDouble();

      if (!du.isFinite || !dv.isFinite) return null;
      if (du < 0 || du > 1 || dv < 0 || dv > 1) return null;

      return (u: du, v: dv);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearMarkers(int viewId) async {
    try {
      await _view(viewId).invokeMethod<void>("clearMarkers");
    } catch (_) {}
  }

  /// Says a milestone out loud, for a user whose eyes are on the log.
  Future<void> speak(int viewId, String text) async {
    try {
      await _view(viewId).invokeMethod<void>("speak", {"text": text});
    } catch (_) {}
  }

  /// Resets world tracking, for starting a scan over from nothing.
  Future<void> restartTracking(int viewId) async {
    try {
      await _view(viewId).invokeMethod<void>("restartTracking");
    } catch (_) {}
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
