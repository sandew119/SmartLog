import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/services/lidar_scanner_service.dart';
import 'package:smartlog2/utils/face_scan.dart';
import 'package:smartlog2/utils/outline_ribbon.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';

/// What is drawn on the log, and how a tap is turned into a place on it.
///
/// The Swift that draws the ribbon and answers the tap cannot be run here, so
/// everything it is *given* is worked out in Dart and checked here: the ribbon
/// is a closed strip of the right width lying in the face's plane, the outline
/// points sit on the traced outline, and a native side that answers a tap
/// with nonsense is treated as "nowhere" and not as a crash.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the outline ribbon', () {
    // A circle of radius 0.2 in the plane z = -1.
    final ring = [
      for (var i = 0; i < 32; i++)
        Vector3(
          0.2 * math.cos(2 * math.pi * i / 32),
          0.2 * math.sin(2 * math.pi * i / 32),
          -1,
        ),
    ];

    final normal = Vector3(0, 0, 1);

    Vector3 vertex(Float32List strip, int i) =>
        Vector3(strip[3 * i], strip[3 * i + 1], strip[3 * i + 2]);

    test('has two vertices for every point, and closes the loop', () {
      final strip = OutlineRibbon.strip(ring, normal, 0.005);

      // 32 points + 1 to close, 2 vertices each, 3 numbers each.
      expect(strip.length, 3 * 2 * 33);

      // The last pair is the first pair.
      expect((vertex(strip, 64) - vertex(strip, 0)).length, lessThan(1e-6));
      expect((vertex(strip, 65) - vertex(strip, 1)).length, lessThan(1e-6));
    });

    test('lies in the plane of the face', () {
      final strip = OutlineRibbon.strip(ring, normal, 0.005);

      for (var i = 0; i < strip.length ~/ 3; i++) {
        expect(vertex(strip, i).z, closeTo(-1, 1e-6));
      }
    });

    test('is as wide as asked, and centred on the ring', () {
      const halfWidth = 0.006;
      final strip = OutlineRibbon.strip(ring, normal, halfWidth);

      for (var i = 0; i < 32; i++) {
        final inner = vertex(strip, 2 * i);
        final outer = vertex(strip, 2 * i + 1);

        expect((outer - inner).length, closeTo(2 * halfWidth, 1e-5));
        expect(((inner + outer) / 2 - ring[i]).length, lessThan(1e-5));
      }
    });

    test('puts the outer edge outside the ring, on every side', () {
      final strip = OutlineRibbon.strip(ring, normal, 0.005);

      // Whichever way round the ring is wound, the two edges are one either
      // side: one inside the circle and one outside.
      for (var i = 0; i < 32; i++) {
        final a = vertex(strip, 2 * i).xy.length;
        final b = vertex(strip, 2 * i + 1).xy.length;

        expect((math.min(a, b) - 0.195).abs(), lessThan(1e-4));
        expect((math.max(a, b) - 0.205).abs(), lessThan(1e-4));
      }
    });

    test('refuses a ring too small to be a ring', () {
      expect(OutlineRibbon.strip(ring.take(2).toList(), normal, 0.005), isEmpty);
    });

    test('is thicker further away, and never a hairline', () {
      expect(
        OutlineRibbon.halfWidthFor(2),
        greaterThan(OutlineRibbon.halfWidthFor(0.6)),
      );
      expect(OutlineRibbon.halfWidthFor(0.01), greaterThanOrEqualTo(0.003));
    });
  });

  group('the outline points of a traced face', () {
    final camera = SyntheticCamera();

    test('sit on the outline, in the plane of the face', () {
      const radius = 0.15;

      final attempt = FaceScanner.detect(
        camera.frame(
          camera.renderFace(
            centre: Vector3(0, 0, -0.7),
            normal: Vector3(0, 0, 1),
            outline: (_) => radius,
          ),
        ),
      );

      final face = attempt.face!;
      final points = face.outlinePoints(samples: 48);

      expect(points.length, 48);

      for (final p in points) {
        // In the face's plane...
        expect((p - face.centre).dot(face.normal).abs(), lessThan(1e-6));

        // ...and a face-radius from its centre.
        expect((p - face.centre).length, closeTo(radius, 0.08 * radius));
      }
    });

    test('draw as a ribbon without a fuss', () {
      final face = FaceScanner.detect(
        camera.frame(
          camera.renderFace(
            centre: Vector3(0, 0, -0.7),
            normal: Vector3(0, 0, 1),
            outline: (_) => 0.15,
          ),
        ),
      ).face!;

      final strip = OutlineRibbon.strip(
        face.outlinePoints(),
        face.normal,
        OutlineRibbon.halfWidthFor(face.distanceMetres),
      );

      expect(strip.length, 3 * 2 * 65);
      expect(strip.every((v) => v.isFinite), isTrue);
    });
  });

  group('resolving a tap', () {
    const channel = MethodChannel('smartlog/lidar_scanner/view_9');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<({double u, double v})?> tapWith(Object? answer) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'viewToImage');
        return answer;
      });

      return LidarScannerService.instance.viewToImage(9, x: 0.5, y: 0.4);
    }

    test('passes on a place in the image', () async {
      final place = await tapWith({'u': 0.25, 'v': 0.75});

      expect(place, isNotNull);
      expect(place!.u, closeTo(0.25, 1e-9));
      expect(place.v, closeTo(0.75, 1e-9));
    });

    test('sends the tap as fractions of the view', () async {
      Map<Object?, Object?>? received;

      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call.arguments as Map<Object?, Object?>;
        return {'u': 0.5, 'v': 0.5};
      });

      await LidarScannerService.instance.viewToImage(9, x: 0.3, y: 0.6);

      expect(received!['x'], 0.3);
      expect(received!['y'], 0.6);
    });

    test('takes nothing as nowhere', () async {
      expect(await tapWith(null), isNull);
    });

    test('takes a place outside the picture as nowhere', () async {
      expect(await tapWith({'u': 1.4, 'v': 0.5}), isNull);
      expect(await tapWith({'u': 0.5, 'v': -0.1}), isNull);
    });

    test('takes nonsense as nowhere, not as a crash', () async {
      expect(await tapWith({'u': 'left', 'v': 0.5}), isNull);
      expect(await tapWith({'u': double.nan, 'v': 0.5}), isNull);
      expect(await tapWith({'v': 0.5}), isNull);
      expect(await tapWith('a string'), isNull);
    });

    test('takes a native side that is not there as nowhere', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'no');
      });

      expect(
        await LidarScannerService.instance.viewToImage(9, x: 0.5, y: 0.5),
        isNull,
      );
    });
  });
}
