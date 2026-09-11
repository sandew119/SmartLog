import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_measurement.dart';
import 'package:smartlog2/utils/log_scan_session.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';

/// Drives a whole scan, frame by frame, through a synthetic log -- the test
/// that says a scan *can* finish, which the previous scanner never had.
///
/// The log lies along world -z. Its near end is 0.6 m in front of where the
/// user starts, and it is [length] long:
///
///     camera at origin  ->  near face at z = -0.6  ...  far face at
///                                                       z = -0.6 - length
void main() {
  const radius = 0.15;
  const length = 2.4;
  const girth = 2 * math.pi * radius;

  var clock = 0.0;

  /// The near end, from where the user starts: centred in view, and turned
  /// [tiltRadians] away from square on -- as when the user stands off to one
  /// side of the end rather than in front of it.
  frameAtNearEnd({bool tracking = true, double tiltRadians = 0}) {
    final camera = SyntheticCamera();

    clock += 0.1;
    return camera.frame(
      camera.renderFace(
        centre: Vector3(0, 0, -0.6),
        normal: Vector3(math.sin(tiltRadians), 0, math.cos(tiltRadians)),
        outline: (_) => radius,
      ),
      tracking: tracking,
      timestamp: clock,
    );
  }

  /// Beside the log, looking at its side, [along] metres from the near end.
  frameAlongside(double along) {
    // Standing 0.8 m to the log's +x side, facing -x.
    final camera = SyntheticCamera(
      transform: Matrix4.translationValues(0.8, 0, -0.6 - along)
        ..rotateY(math.pi / 2),
    );

    clock += 0.1;
    return camera.frame(
      camera.renderCylinderSide(
        centre: Vector3(0, 0, -0.8),
        axis: Vector3(1, 0, 0),
        radius: radius,
      ),
      timestamp: clock,
    );
  }

  /// Past the far end, turned round to face it.
  frameAtFarEnd() {
    final camera = SyntheticCamera(
      transform: Matrix4.translationValues(0, 0, -1.2 - length)
        ..rotateY(math.pi),
    );

    clock += 0.1;
    return camera.frame(
      camera.renderFace(
        centre: Vector3(0, 0, -0.6),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      ),
      timestamp: clock,
    );
  }

  /// The near end again, but from beyond the far end -- as a user who got
  /// turned round would see it. Faces the same way as the near end.
  frameAtSomeOtherEndFacingTheWrongWay() {
    final camera = SyntheticCamera(
      transform: Matrix4.translationValues(0, 0, -0.6 - length + 0.6),
    );

    clock += 0.1;
    return camera.frame(
      camera.renderFace(
        centre: Vector3(0, 0, -0.6),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      ),
      timestamp: clock,
    );
  }

  setUp(() => clock = 0);

  group('a complete scan', () {
    late LogScanSession session;
    final events = <ScanEvent>[];

    setUp(() {
      session = LogScanSession();
      events.clear();

      void feed(frame) {
        final event = session.onFrame(frame);
        if (event != null) events.add(event);
      }

      for (var i = 0; i < 6; i++) {
        feed(frameAtNearEnd());
      }

      for (var along = 0.3; along < length - 0.2; along += 0.1) {
        feed(frameAlongside(along));
      }

      // Walk back over the middle, as people do when they check their work.
      for (var along = length - 0.4; along > 0.4; along -= 0.15) {
        feed(frameAlongside(along));
      }

      for (var i = 0; i < 6; i++) {
        feed(frameAtFarEnd());
      }
    });

    test('goes through every step and finishes on its own', () {
      expect(events, [
        ScanEvent.nearEndLocked,
        ScanEvent.farEndFound,
        ScanEvent.finished,
      ]);
      expect(session.step, ScanStep.finished);
    });

    test('measures the length as the straight line between the ends', () {
      final result = session.result!;

      expect(result.lengthMetres, closeTo(length, 0.02));
      expect(result.lengthEstimated, isFalse);
    });

    test('measures the girth of both ends', () {
      final result = session.result!;

      expect(result.faceGirthMetres, closeTo(girth, 0.02 * girth));
      expect(result.farFaceGirthMetres, closeTo(girth, 0.02 * girth));
    });

    test('reads the trunk on the walk, and agrees with the ends', () {
      final result = session.result!;

      expect(result.trunkReadings, greaterThan(20));
      expect(result.minimumGirth.trunkSeen, isTrue);
      expect(result.minimumGirth.girthMetres, closeTo(girth, 0.03 * girth));

      final trunk = result.profile.where((p) => p.inferred).toList();
      expect(trunk, isNotEmpty);

      for (final slice in trunk) {
        expect(slice.girthMetres, closeTo(girth, 0.05 * girth));
      }
    });

    test('hands the rest of the app a measurement it can price', () {
      final measurement = session.result!.toMeasurement();

      expect(measurement.source, MeasurementSourceKind.lidar);
      expect(measurement.minGirthInches, closeTo(girth * 39.37, 0.03 * girth * 39.37));
      expect(measurement.lengthFeet, closeTo(length * 3.2808, 0.1));
      expect(measurement.faceGirthInches, isNotNull);
      expect(measurement.farFaceGirthInches, isNotNull);
      expect(measurement.lengthEstimated, isFalse);
      expect(measurement.quality, MeasurementQuality.good);
    });
  });

  group('locking on to the near end', () {
    test('does not lock on a single frame', () {
      final session = LogScanSession();

      expect(session.onFrame(frameAtNearEnd()), isNull);
      expect(session.step, ScanStep.nearEnd);
      expect(session.currentFace, isNotNull);
      expect(session.guidance.headline, 'Hold still…');
    });

    test('ignores frames while tracking is unreliable', () {
      final session = LogScanSession();

      for (var i = 0; i < 10; i++) {
        session.onFrame(frameAtNearEnd(tracking: false));
      }

      expect(session.step, ScanStep.nearEnd);
      expect(session.guidance.tone, GuidanceTone.warning);
    });

    test('asks for square-on first, then accepts a steady angle anyway', () {
      final session = LogScanSession();

      // 40 degrees: inside what the detector accepts, outside square.
      final tilt = 40 * math.pi / 180;

      ScanEvent? event;
      var frames = 0;

      while (event == null && frames < 80) {
        event = session.onFrame(frameAtNearEnd(tiltRadians: tilt));
        frames++;

        if (frames == 6) {
          expect(session.step, ScanStep.nearEnd);
          expect(session.guidance.headline, contains('straight'));
        }
      }

      expect(event, ScanEvent.nearEndLocked);

      // Not instantly -- the user was given the chance to straighten up.
      expect(
        frames * 0.1,
        greaterThanOrEqualTo(LogScanSession.patienceSeconds),
      );
    });

    test('"Use this" accepts the face in view straight away', () {
      final session = LogScanSession();

      session.onFrame(frameAtNearEnd());

      expect(session.canUseCurrentFace, isTrue);
      expect(session.useCurrentFace(), ScanEvent.nearEndLocked);
      expect(session.step, ScanStep.walk);
    });
  });

  group('the far end', () {
    LogScanSession walkedSession() {
      final session = LogScanSession();

      for (var i = 0; i < 6; i++) {
        session.onFrame(frameAtNearEnd());
      }
      for (var along = 0.3; along < length - 0.2; along += 0.1) {
        session.onFrame(frameAlongside(along));
      }

      return session;
    }

    test('a face turned the same way as the near end is not the far end', () {
      final session = walkedSession()..atFarEnd();

      for (var i = 0; i < 8; i++) {
        session.onFrame(frameAtSomeOtherEndFacingTheWrongWay());
      }

      expect(session.step, ScanStep.farEnd);
      expect(session.guidance.headline, contains('already scanned'));
    });

    test('can be marked by eye when it cannot be scanned', () {
      final session = walkedSession();

      expect(session.canMarkFarEnd, isTrue);
      expect(session.markFarEndHere(), ScanEvent.finished);

      final result = session.result!;

      expect(result.lengthEstimated, isTrue);
      expect(result.farFace, isNull);

      // The furthest the user aimed along the trunk -- short of the true end
      // by however much of the trunk near the far end went unseen.
      expect(result.lengthMetres, inInclusiveRange(length - 0.6, length + 0.05));

      final measurement = result.toMeasurement();
      expect(measurement.lengthEstimated, isTrue);
      expect(measurement.quality, MeasurementQuality.fair);
      expect(measurement.limitingFactorMessage, contains('estimate'));
    });

    test('cannot be marked before the user has gone anywhere', () {
      final session = LogScanSession();

      for (var i = 0; i < 6; i++) {
        session.onFrame(frameAtNearEnd());
      }

      expect(session.step, ScanStep.walk);
      expect(session.canMarkFarEnd, isFalse);
      expect(session.markFarEndHere(), isNull);
    });
  });

  test('starting over forgets everything', () {
    final session = LogScanSession();

    for (var i = 0; i < 6; i++) {
      session.onFrame(frameAtNearEnd());
    }
    session.onFrame(frameAlongside(1.0));

    session.startOver();

    expect(session.step, ScanStep.nearEnd);
    expect(session.nearFace, isNull);
    expect(session.trunkReadings, 0);
    expect(session.result, isNull);
  });

  test('every rejection has something to say', () {
    for (final reason in GirthSource.values) {
      expect(reason.name, isNotEmpty);
    }

    final session = LogScanSession();
    expect(session.guidance.headline, isNotEmpty);
  });
}
