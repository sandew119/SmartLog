import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/face_scan.dart';
import 'package:smartlog2/utils/face_segmentation.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';

/// The cut-face finder against the scenes a timber yard actually presents,
/// rendered through a noisy sensor model.
///
/// The clean tests in `face_scan_test.dart` all passed while a phone struggled.
/// These are the cases that explained it: every one of them failed, or gave a
/// wrong answer with confidence, against the finder they replaced --
///
///   - a log end lying on the ground was found in 0 of 30 frames, from every
///     height and distance tried;
///   - a hexagonal stack of seven ends was measured as ONE face of three times
///     the girth;
///   - an 8-10 inch girth object was refused as "more than one log" or "not
///     flat" in nearly every frame.
///
/// The sensor model (see `SensorModel`) is a deliberately harsh stand-in for
/// an iPhone 13 Pro. What these tests establish is the behaviour of the
/// *algorithm* under noise, edge smear and dropped returns; the accuracy
/// against a tape on a real log is still something only a device can say.
void main() {
  final camera = SyntheticCamera();

  double girthOf(double radius) => 2 * math.pi * radius;

  /// Runs [frames] noisy renders of [scene] and returns each attempt.
  List<FaceAttempt> detectAll(
    Float32List scene, {
    SyntheticCamera? through,
    int frames = 30,
    int seed = 7,
    SensorModel model = const SensorModel(),
  }) {
    final rng = math.Random(seed);
    final cam = through ?? camera;

    return [
      for (var i = 0; i < frames; i++)
        FaceScanner.detect(cam.sensedFrame(scene, rng, model: model)),
    ];
  }

  double foundShare(List<FaceAttempt> attempts) =>
      attempts.where((a) => a.isFound).length / attempts.length;

  double meanGirth(List<FaceAttempt> attempts) {
    final found = attempts.where((a) => a.isFound).toList();
    return found.map((a) => a.face!.girthMetres).reduce((a, b) => a + b) /
        found.length;
  }

  double spread(List<FaceAttempt> attempts) {
    final girths = attempts
        .where((a) => a.isFound)
        .map((a) => a.face!.girthMetres)
        .toList();
    final mean = girths.reduce((a, b) => a + b) / girths.length;
    final variance =
        girths.map((g) => (g - mean) * (g - mean)).reduce((a, b) => a + b) /
            girths.length;
    return math.sqrt(variance) / mean;
  }

  group('a round end on noisy depth', () {
    for (final distance in [0.5, 0.8, 1.2]) {
      test('at ${distance}m is found every frame and traced steadily', () {
        const radius = 0.15;

        final attempts = detectAll(
          camera.renderFace(
            centre: Vector3(0, 0, -distance),
            normal: Vector3(0, 0, 1),
            outline: (_) => radius,
          ),
          frames: 40,
        );

        expect(foundShare(attempts), greaterThanOrEqualTo(0.95));

        // Frame to frame the girth barely moves -- which is what lets a lock
        // on a handful of frames be trusted.
        expect(spread(attempts), lessThan(0.006));

        // And it is the right size, within what the sensor's edges allow.
        expect(
          meanGirth(attempts),
          closeTo(girthOf(radius), 0.03 * girthOf(radius)),
        );
      });
    }
  });

  group('a small object', () {
    // The failure that started this: an 8 inch girth cylinder, refused in
    // nearly every frame by tolerances chosen for a 30 cm log.
    test('of 8 inch girth is found when held about a forearm away', () {
      const girth = 8 * 0.0254;
      const radius = girth / (2 * math.pi);

      final attempts = detectAll(
        camera.renderFace(
          centre: Vector3(0, 0, -0.4),
          normal: Vector3(0, 0, 1),
          outline: (_) => radius,
        ),
        frames: 40,
      );

      expect(foundShare(attempts), greaterThanOrEqualTo(0.9));
      expect(meanGirth(attempts), closeTo(girth, 0.08 * girth));
    });

    test('of 10 inch girth is found at half a metre', () {
      const girth = 10 * 0.0254;
      const radius = girth / (2 * math.pi);

      final attempts = detectAll(
        camera.renderFace(
          centre: Vector3(0, 0, -0.5),
          normal: Vector3(0, 0, 1),
          outline: (_) => radius,
        ),
        frames: 40,
      );

      expect(foundShare(attempts), greaterThanOrEqualTo(0.9));
      expect(meanGirth(attempts), closeTo(girth, 0.08 * girth));
    });

    test('too small to resolve at range says so instead of guessing', () {
      const radius = 0.03;

      final attempts = detectAll(
        camera.renderFace(
          centre: Vector3(0, 0, -0.7),
          normal: Vector3(0, 0, 1),
          outline: (_) => radius,
        ),
        frames: 20,
      );

      // Refused, with a reason the user can act on ("move closer") -- not a
      // wildly wrong girth.
      expect(foundShare(attempts), lessThan(0.2));
      expect(
        attempts.where((a) => !a.isFound).every(
              (a) =>
                  a.rejection == FaceRejection.tooSmall ||
                  a.rejection == FaceRejection.notFlat ||
                  a.rejection == FaceRejection.outlineIncomplete,
            ),
        isTrue,
      );
    });
  });

  group('an end resting on the ground', () {
    // Depth is continuous from the face straight down onto the earth, which is
    // what stopped the old finder every time. Height and distance are the
    // two things a person varies.
    for (final (height, distance) in [
      (1.0, 0.9),
      (1.0, 1.2),
      (1.3, 0.9),
      (1.3, 1.2),
    ]) {
      test('seen from ${height}m up, ${distance}m away, is found', () {
        const radius = 0.15;

        final pitch = math.atan2(height - radius, distance);
        final tilted = SyntheticCamera(
          transform: Matrix4.identity()..rotateX(-pitch),
        );

        final scene = nearest(
          tilted.renderWorldFace(
            centre: Vector3(0, -height + radius, -distance),
            normal: Vector3(0, 0, 1),
            outline: (_) => radius,
          ),
          tilted.renderWorldGround(y: -height),
        );

        final attempts = detectAll(scene, through: tilted);

        expect(foundShare(attempts), greaterThanOrEqualTo(0.9));

        // The strip of ground where the earth meets the face cannot be told
        // from the face by depth alone, so this is looser than a free-standing
        // end. The point is that it is measured, and close.
        expect(
          meanGirth(attempts),
          closeTo(girthOf(radius), 0.08 * girthOf(radius)),
        );
      });
    }

    test('raised on a bearer is found too', () {
      const radius = 0.15;
      const height = 1.2, distance = 1.2, gap = 0.10;

      final pitch = math.atan2(height - radius - gap, distance);
      final tilted = SyntheticCamera(
        transform: Matrix4.identity()..rotateX(-pitch),
      );

      final scene = nearest(
        tilted.renderWorldFace(
          centre: Vector3(0, -height + radius + gap, -distance),
          normal: Vector3(0, 0, 1),
          outline: (_) => radius,
        ),
        tilted.renderWorldGround(y: -height),
      );

      final attempts = detectAll(scene, through: tilted);

      expect(foundShare(attempts), greaterThanOrEqualTo(0.9));
      expect(
        meanGirth(attempts),
        closeTo(girthOf(radius), 0.06 * girthOf(radius)),
      );
    });
  });

  group('ends in a stack', () {
    const radius = 0.12;

    Float32List stack(List<Vector2> centres) {
      var scene = Float32List.fromList(
        List.filled(camera.width * camera.height, 6.0),
      );

      for (final c in centres) {
        scene = nearest(
          scene,
          camera.renderFace(
            centre: Vector3(c.x, c.y, -0.9),
            normal: Vector3(0, 0, 1),
            outline: (_) => radius,
            backgroundDepth: 6,
          ),
        );
      }

      return scene;
    }

    test('three flush ends: the middle one is measured, not the row', () {
      final attempts = detectAll(
        stack([Vector2(-2 * radius, 0), Vector2(0, 0), Vector2(2 * radius, 0)]),
        frames: 20,
      );

      expect(foundShare(attempts), greaterThanOrEqualTo(0.8));

      // One log's girth -- not the 2.5x a whole row would trace.
      expect(meanGirth(attempts), lessThan(1.15 * girthOf(radius)));
      expect(meanGirth(attempts), greaterThan(0.85 * girthOf(radius)));
    });

    test('seven flush ends in a hexagon: never reported as one big face', () {
      // The case that was measured at three times the girth with full
      // confidence. A hexagonal cluster is nearly round, so no shape test can
      // catch it; only separating the ends can.
      final centres = [
        Vector2(0, 0),
        for (var k = 0; k < 6; k++)
          Vector2(
            2 * radius * math.cos(k * math.pi / 3),
            2 * radius * math.sin(k * math.pi / 3),
          ),
      ];

      final attempts = detectAll(stack(centres), frames: 20);

      expect(foundShare(attempts), greaterThanOrEqualTo(0.7));

      for (final attempt in attempts.where((a) => a.isFound)) {
        expect(
          attempt.face!.girthMetres,
          lessThan(1.25 * girthOf(radius)),
          reason: 'a cluster of ends was traced as one',
        );
      }

      expect(meanGirth(attempts), greaterThan(0.85 * girthOf(radius)));
    });

    test('ends set back from one another are measured normally', () {
      final scene = nearest(
        camera.renderFace(
          centre: Vector3(0, 0, -0.65),
          normal: Vector3(0, 0, 1),
          outline: (_) => radius,
        ),
        camera.renderFace(
          centre: Vector3(0.235, 0, -0.78),
          normal: Vector3(0, 0, 1),
          outline: (_) => radius,
        ),
      );

      final attempts = detectAll(scene, frames: 20);

      expect(foundShare(attempts), greaterThanOrEqualTo(0.9));
      expect(
        meanGirth(attempts),
        closeTo(girthOf(radius), 0.06 * girthOf(radius)),
      );
    });
  });

  group('the side of a trunk', () {
    // Curvature, not size, tells a flat end from a curved side -- so it has
    // to hold from a thin pole to a big log.
    for (final radius in [0.08, 0.15, 0.3, 0.5]) {
      test('of radius ${radius}m is never taken for an end', () {
        final attempts = detectAll(
          camera.renderCylinderSide(
            centre: Vector3(0, 0, -0.9),
            axis: Vector3(1, 0, 0),
            radius: radius,
          ),
          frames: 20,
        );

        expect(foundShare(attempts), lessThanOrEqualTo(0.1));
      });
    }
  });

  group('a face seen at an angle', () {
    for (final degrees in [20, 40, 60]) {
      test('$degrees degrees off square is traced in its own plane', () {
        const radius = 0.15;
        final tilt = degrees * math.pi / 180;

        final attempts = detectAll(
          camera.renderFace(
            centre: Vector3(0, 0, -0.8),
            normal: Vector3(math.sin(tilt), 0, math.cos(tilt)),
            outline: (_) => radius,
          ),
          frames: 20,
        );

        expect(foundShare(attempts), greaterThanOrEqualTo(0.9));
        expect(
          meanGirth(attempts),
          closeTo(girthOf(radius), 0.04 * girthOf(radius)),
        );
      });
    }
  });

  group('an aim a little off the face', () {
    test('still finds the face when the reticle is on a radial crack', () {
      // A one-pixel end check, which is what a real one looks like at arm's
      // length once the sensor has smoothed it. Cracks wider than that are a
      // known limit -- see FaceSegmentation._closeGaps.
      const radius = 0.15;

      final scene = camera.renderFace(
        centre: Vector3(0, 0, -0.7),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      );

      // Dropped returns from the rim in to the pith, with the reticle sitting
      // on the tip.
      for (var y = 0; y <= camera.height ~/ 2; y++) {
        scene[y * camera.width + 64] = 0;
      }

      final attempts = detectAll(scene, frames: 20);

      expect(foundShare(attempts), greaterThanOrEqualTo(0.9));
      expect(
        meanGirth(attempts),
        closeTo(girthOf(radius), 0.06 * girthOf(radius)),
      );
    });
  });

  group('separating touching ends', () {
    const width = 128, height = 96;

    List<int> discs(List<(double, double, double)> discs) {
      final out = <int>[];

      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          for (final (cx, cy, r) in discs) {
            if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) {
              out.add(y * width + x);
              break;
            }
          }
        }
      }

      return out;
    }

    int cell(List<int> pixels, int x, int y, {double opening = 0}) =>
        FaceSegmentation.cellContaining(
          pixels: pixels,
          seed: y * width + x,
          width: width,
          height: height,
          openingPixels: opening,
        ).length;

    test('two touching discs give one disc, whichever the seed is in', () {
      final pixels = discs([(40, 48, 15), (70.5, 48, 15)]);
      final one = discs([(40, 48, 15)]).length;

      expect(cell(pixels, 40, 48), closeTo(one, 0.1 * one));
      expect(cell(pixels, 70, 48), closeTo(one, 0.1 * one));
    });

    test('a hexagon of seven gives one disc, not the cluster', () {
      const r = 14.7;

      final ds = <(double, double, double)>[(64, 48, r)];
      for (var k = 0; k < 6; k++) {
        ds.add((
          64 + 2 * r * math.cos(k * math.pi / 3),
          48 + 2 * r * math.sin(k * math.pi / 3),
          r,
        ));
      }

      final pixels = discs(ds);
      final one = discs([(64, 48, r)]).length;

      expect(pixels.length, greaterThan(6 * one));
      expect(cell(pixels, 64, 48), closeTo(one, 0.6 * one));
    });

    test('a single face with a crack and a knot stays whole', () {
      final base = discs([(50, 48, 20)]);

      final cracked = base
          .where((i) => !((i % width - 50).abs() < 1 && (i ~/ width) < 40))
          .toList();

      final knotted = cracked
          .where(
            (i) =>
                ((i % width - 52) * (i % width - 52) +
                    (i ~/ width - 52) * (i ~/ width - 52)) >
                9,
          )
          .toList();

      // The crack and the knot are filled, so the whole face comes back.
      expect(cell(knotted, 50, 48), closeTo(base.length, 0.03 * base.length));
    });

    test('a thin strip across the frame is not part of the face', () {
      final disc = discs([(64, 40, 15)]);

      final strip = <int>[
        for (var x = 0; x < width; x++)
          for (var y = 56; y < 59; y++) y * width + x,
      ];

      final pixels = {...disc, ...strip}.toList();

      expect(
        cell(pixels, 64, 40, opening: 3.4),
        closeTo(disc.length, 0.1 * disc.length),
      );
    });
  });
}
