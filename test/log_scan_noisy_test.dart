import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/log_girth_model.dart';
import 'package:smartlog2/utils/log_scan_session.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';
import 'support/synthetic_logs.dart';

/// A whole scan of a whole log, through a noisy sensor and a wandering pose.
///
/// `log_scan_session_test.dart` drives the same flow on perfect frames and
/// perfect tracking, which proves the steps can be completed and nothing more.
/// A real scan has depth noise, edges that smear, and a world that drifts a
/// little as the phone is walked down the log. This checks that the answers
/// -- the ends, the length, and above all the *thinnest girth of the whole
/// log*, which is what is billed on -- survive that.
///
/// The log lies along world -z. Its near end is 0.6 m in front of where the
/// user starts:
///
///     camera at origin  ->  near face at z = -0.6  ...  far face at
///                                                       z = -0.6 - length
void main() {
  const length = 2.4;

  /// Drift, as a share of the distance walked, and a little jitter frame to
  /// frame. Together they stand in for ARKit's visual-inertial tracking.
  Matrix4 pose({
    required Matrix4 base,
    required double walked,
    required math.Random rng,
    double drift = 0.01,
    double jitterMetres = 0.003,
  }) {
    final wander = Matrix4.identity()
      ..translateByVector3(
        Vector3(
          drift * walked + jitterMetres * gaussian(rng),
          jitterMetres * gaussian(rng),
          jitterMetres * gaussian(rng),
        ),
      )
      ..rotateY(drift * 0.4 * walked + 0.002 * gaussian(rng))
      ..rotateX(0.002 * gaussian(rng));

    return wander * base;
  }

  /// A full scan of a log with the given radius profile, returning the
  /// finished session.
  LogScanSession scan(
    double Function(double along) radiusAt, {
    int seed = 5,
    double drift = 0.01,
  }) {
    final rng = math.Random(seed);
    final session = LogScanSession();

    var clock = 0.0;

    void feed(SyntheticCamera camera, Float32List scene, double walked) {
      clock += 0.1;

      final moved = SyntheticCamera(
        transform: pose(
          base: camera.transform,
          walked: walked,
          rng: rng,
          drift: drift,
        ),
      );

      session.onFrame(moved.sensedFrame(scene, rng, timestamp: clock));
    }

    // Near end, from a step away.
    final nearCamera = SyntheticCamera();
    final nearScene = nearCamera.renderFace(
      centre: Vector3(0, 0, -0.6),
      normal: Vector3(0, 0, 1),
      outline: (_) => radiusAt(0),
    );

    for (var i = 0; i < 8; i++) {
      feed(nearCamera, nearScene, 0);
    }

    // The walk, beside the log, keeping it in the middle of the screen.
    for (var along = 0.3; along < length - 0.2; along += 0.08) {
      final camera = SyntheticCamera(
        transform: Matrix4.translationValues(0.8, 0, -0.6 - along)
          ..rotateY(math.pi / 2),
      );

      final scene = camera.renderLogSide(
        origin: Vector3(0, 0, -0.6),
        axis: Vector3(0, 0, -1),
        radiusAt: radiusAt,
        length: length,
      );

      feed(camera, scene, along);
    }

    // The far end, from beyond it.
    final farCamera = SyntheticCamera(
      transform: Matrix4.translationValues(0, 0, -1.2 - length)
        ..rotateY(math.pi),
    );

    final farScene = farCamera.renderFace(
      centre: Vector3(0, 0, -0.6),
      normal: Vector3(0, 0, 1),
      outline: (_) => radiusAt(length),
    );

    for (var i = 0; i < 10; i++) {
      feed(farCamera, farScene, length);
    }

    return session;
  }

  double girthOf(double radius) => 2 * math.pi * radius;

  group('a uniform log', () {
    late LogScanSession session;

    setUp(() => session = scan((_) => 0.15));

    test('is scanned to the end through noise and drift', () {
      expect(session.step, ScanStep.finished, reason: session.report());
    });

    test('has both ends and the length right', () {
      final result = session.result!;

      expect(result.lengthMetres, closeTo(length, 0.04 * length));
      expect(
        result.faceGirthMetres,
        closeTo(girthOf(0.15), 0.04 * girthOf(0.15)),
      );
      expect(
        result.farFaceGirthMetres,
        closeTo(girthOf(0.15), 0.04 * girthOf(0.15)),
      );
    });

    test('is not undercut by the noise along its trunk', () {
      // The thinnest girth of a log with no waist is the girth of the log.
      // Taking a minimum over noisy readings finds the noise as much as the
      // log; this is what says the margin against that is enough.
      final result = session.result!;

      expect(
        result.minimumGirth.girthMetres,
        closeTo(girthOf(0.15), 0.02 * girthOf(0.15)),
      );
    });

    test('reads a steady trunk all the way along, not just at the ends', () {
      // The trunk is anchored to the ends, so what is left of it is real
      // variation along the log. On a uniform one there is none.
      final trunk = session.result!.profile.where((p) => p.inferred).toList();

      expect(trunk.length, greaterThan(10));

      for (final slice in trunk) {
        expect(slice.girthMetres, closeTo(girthOf(0.15), 0.03 * girthOf(0.15)));
      }
    });

    test('is never undercut, whichever way the noise falls', () {
      for (final seed in [1, 2, 3]) {
        final result = scan((_) => 0.15, seed: seed).result!;

        expect(
          result.minimumGirth.girthMetres,
          greaterThan(0.97 * girthOf(0.15)),
          reason: 'seed $seed',
        );
      }
    });
  });

  group('a log that tapers', () {
    test('bills on the thin end, and finds it', () {
      // 16 cm at the near end down to 13 cm at the far.
      final session = scan((a) => 0.16 - 0.03 * (a / length));

      expect(session.step, ScanStep.finished, reason: session.report());

      final result = session.result!;

      // The thin end is the thinnest place, and the trunk must not find a
      // thinner one: a taper is not a waist.
      expect(
        result.minimumGirth.girthMetres,
        closeTo(girthOf(0.13), 0.03 * girthOf(0.13)),
      );

      expect(result.faceGirthMetres, greaterThan(result.farFaceGirthMetres!));
    });
  });

  group('a log with a waist', () {
    test('finds the thin place between the ends', () {
      // 15 cm at both ends, pinched to 12 cm in the middle.
      double radius(double a) {
        final d = (a - length / 2) / 0.35;
        return 0.15 - 0.03 * math.exp(-d * d);
      }

      final session = scan(radius);

      expect(session.step, ScanStep.finished, reason: session.report());

      final result = session.result!;

      // The waist is what the log is billed on, so the scan must find it --
      // not report the ends. And it must not find one that is not there.
      expect(result.minimumGirth.source, GirthSource.trunk);
      expect(
        result.minimumGirth.girthMetres,
        closeTo(girthOf(0.12), 0.05 * girthOf(0.12)),
      );
      expect(result.minimumGirth.girthMetres, lessThan(girthOf(0.15) * 0.93));
    });
  });
}
