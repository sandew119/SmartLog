import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/services/lidar_scanner_service.dart';

/// The native side of this feature was written without a device to test on,
/// so the Dart boundary has to assume the payload may be missing, truncated,
/// mistyped, or full of NaN. These tests pin down that it degrades to a safe
/// value in every one of those cases rather than crashing the scan screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Float32List xyz(List<double> values) => Float32List.fromList(values);

  group('parseCapture — valid payloads', () {
    test('decodes a flat xyz buffer into points', () {
      final capture = LidarScannerService.parseCapture({
        "points": xyz([1, 2, 3, 4, 5, 6]),
        "taps": xyz([0, 0, 1]),
        "trackingState": "normal",
      })!;

      expect(capture.points.length, 2);
      expect(capture.points.first.x, closeTo(1, 1e-6));
      expect(capture.points.first.z, closeTo(3, 1e-6));
      expect(capture.points.last.y, closeTo(5, 1e-6));

      expect(capture.taps.length, 1);
      expect(capture.trackingState, "normal");
      expect(capture.isTrackingReliable, isTrue);
    });

    test('accepts a plain List<double> as well as a typed buffer', () {
      final capture = LidarScannerService.parseCapture({
        "points": <double>[1, 2, 3],
        "trackingState": "normal",
      })!;

      expect(capture.points.length, 1);
    });

    test('treats limited tracking as unreliable', () {
      final capture = LidarScannerService.parseCapture({
        "points": xyz([1, 2, 3]),
        "trackingState": "limited",
      })!;

      expect(capture.isTrackingReliable, isFalse);
    });
  });

  group('parseCapture — malformed payloads', () {
    test('returns null for a null payload', () {
      expect(LidarScannerService.parseCapture(null), isNull);
    });

    test('returns null when points are missing entirely', () {
      expect(
        LidarScannerService.parseCapture({"trackingState": "normal"}),
        isNull,
      );
    });

    test('returns null for an empty point cloud', () {
      expect(
        LidarScannerService.parseCapture({"points": xyz([])}),
        isNull,
      );
    });

    test('returns null when points are the wrong type', () {
      expect(
        LidarScannerService.parseCapture({"points": "not a buffer"}),
        isNull,
      );
      expect(
        LidarScannerService.parseCapture({"points": 42}),
        isNull,
      );
    });

    test('ignores a trailing partial point rather than reading past the end',
        () {
      // 7 floats = 2 complete points plus a dangling one.
      final capture = LidarScannerService.parseCapture({
        "points": xyz([1, 2, 3, 4, 5, 6, 7]),
      })!;

      expect(capture.points.length, 2);
    });

    test('drops NaN and infinite points instead of poisoning the fit', () {
      final capture = LidarScannerService.parseCapture({
        "points": xyz([
          1, 2, 3, // good
          double.nan, 5, 6, // bad
          7, double.infinity, 9, // bad
          10, 11, 12, // good
        ]),
      })!;

      expect(capture.points.length, 2);
      expect(capture.points.first.x, closeTo(1, 1e-6));
      expect(capture.points.last.x, closeTo(10, 1e-6));
    });

    test('returns null when every point is non-finite', () {
      expect(
        LidarScannerService.parseCapture({
          "points": xyz([double.nan, double.nan, double.nan]),
        }),
        isNull,
      );
    });

    test('defaults tracking state when the native side omits it', () {
      final capture = LidarScannerService.parseCapture({
        "points": xyz([1, 2, 3]),
      })!;

      expect(capture.trackingState, "unknown");
      expect(capture.isTrackingReliable, isFalse);
    });

    test('tolerates a mistyped tracking state', () {
      final capture = LidarScannerService.parseCapture({
        "points": xyz([1, 2, 3]),
        "trackingState": 7,
      })!;

      expect(capture.trackingState, "unknown");
    });

    test('tolerates malformed taps without losing the points', () {
      final capture = LidarScannerService.parseCapture({
        "points": xyz([1, 2, 3]),
        "taps": "garbage",
      })!;

      expect(capture.points.length, 1);
      expect(capture.taps, isEmpty);
    });
  });

  group('isSupported', () {
    test('is false when the native module is absent', () async {
      // No handler registered -> MissingPluginException, which must be
      // swallowed into "unsupported" rather than thrown at the UI.
      final supported = await LidarScannerService.instance.isSupported();
      expect(supported, isFalse);
    });
  });
}
