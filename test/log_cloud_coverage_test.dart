import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/log_cloud_coverage.dart';
import 'package:smartlog2/utils/scan_coverage.dart';
import 'package:vector_math/vector_math_64.dart';

/// Builds the point cloud a depth sensor would return for a log.
///
/// Surface points only, unless a cut face is asked for -- which is exactly
/// the distinction the whole scan flow now rests on. A sensor sweeping the
/// side of a trunk sees a ring; one pointed at the sawn end sees a disc.
List<Vector3> logCloud({
  double length = 3.0,
  double radius = 0.2,
  double arcDegrees = 360,
  bool capStart = false,
  bool capEnd = false,
  Vector3? direction,
  int rings = 260,
  int perRing = 72,
  int capPoints = 900,
  int strayPointsPerEnd = 0,
}) {
  final axis = (direction ?? Vector3(0, 0, 1))..normalize();

  // Any two vectors across the axis; the cloud only has to be consistent.
  final helper = axis.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
  final u = axis.cross(helper)..normalize();
  final v = axis.cross(u)..normalize();

  final points = <Vector3>[];
  final arc = arcDegrees * math.pi / 180;

  for (var i = 0; i < rings; i++) {
    final t = length * i / (rings - 1);

    for (var j = 0; j < perRing; j++) {
      final theta = arc * j / perRing;

      points.add(
        axis * t + u * (radius * math.cos(theta)) + v * (radius * math.sin(theta)),
      );
    }
  }

  /// A cut face, sampled evenly over its area the way a sensor pointed at
  /// it would be -- so the density is uniform per unit area, not per unit
  /// radius, which is what makes the fill figure mean something.
  void addCap(double t) {
    final random = math.Random(7);

    for (var i = 0; i < capPoints; i++) {
      // sqrt keeps the sampling uniform by area rather than crowding the
      // centre, which is how a real depth map lands on a flat disc.
      final r = radius * math.sqrt(random.nextDouble());
      final theta = random.nextDouble() * arc;

      points.add(
        axis * t + u * (r * math.cos(theta)) + v * (r * math.sin(theta)),
      );
    }
  }

  /// Loose returns scattered inside the trunk's silhouette, of the kind a
  /// real sensor produces: reflections, a passing hand, the log behind.
  ///
  /// Placed in the end sections on purpose. Those are where a few stray
  /// points would be read as a sawn face, and being told an end had been
  /// seen when it had not is the one failure this whole flow exists to
  /// prevent.
  void addStrays(double t) {
    final random = math.Random(11);

    for (var i = 0; i < strayPointsPerEnd; i++) {
      final r = radius * 0.45 * random.nextDouble();
      final theta = random.nextDouble() * 2 * math.pi;

      points.add(
        axis * t + u * (r * math.cos(theta)) + v * (r * math.sin(theta)),
      );
    }
  }

  if (capStart) addCap(0);
  if (capEnd) addCap(length);

  if (strayPointsPerEnd > 0) {
    addStrays(length * 0.005);
    addStrays(length * 0.995);
  }

  return points;
}

void main() {
  group('finding the log in the cloud', () {
    test('the axis and length are recovered', () {
      final progress = LogCloudCoverage.analyse(
        logCloud(length: 3.0, radius: 0.2),
      );

      expect(progress.axisLengthMetres, closeTo(3.0, 0.05));
      expect(progress.pointCount, greaterThan(1000));
    });

    test('an axis at an angle is recovered just as well', () {
      // The log will not be lying along a world axis in a timber yard.
      final progress = LogCloudCoverage.analyse(
        logCloud(length: 2.5, direction: Vector3(1, 0.4, -0.7)),
      );

      expect(progress.axisLengthMetres, closeTo(2.5, 0.06));
    });

    test('a cloud with no dominant direction is refused', () {
      // A wall or the ground, not a log.
      final flat = <Vector3>[
        for (var i = 0; i < 40; i++)
          for (var j = 0; j < 40; j++)
            Vector3(i * 0.02, j * 0.02, 0),
      ];

      final progress = LogCloudCoverage.analyse(flat);

      // Either refused outright, or so short that the length gate catches
      // it -- both leave the user unable to finish, which is the point.
      expect(ScanCoverage(progress).isReady, isFalse);
    });

    test('too few points is refused', () {
      expect(
        LogCloudCoverage.analyse(const []).pointCount,
        0,
      );
    });
  });

  group('a cut face fills its disc; the trunk never does', () {
    test('an unscanned end reads as empty', () {
      // The sweep stopped here. Points sit in a ring at the trunk radius
      // and the middle of the disc is empty.
      final progress = LogCloudCoverage.analyse(logCloud());

      expect(progress.endFillStart, lessThan(0.1));
      expect(progress.endFillEnd, lessThan(0.1));
    });

    test('a scanned cut face reads as filled', () {
      final progress = LogCloudCoverage.analyse(
        logCloud(capStart: true, capEnd: true),
      );

      expect(
        progress.endFillStart,
        greaterThan(ScanCoverage.endFillThreshold),
      );
      expect(
        progress.endFillEnd,
        greaterThan(ScanCoverage.endFillThreshold),
      );
    });

    test('one end scanned, one not, is told apart', () {
      final progress = LogCloudCoverage.analyse(logCloud(capStart: true));

      expect(ScanCoverage(progress).nearEndSeen, isTrue);
      expect(ScanCoverage(progress).farEndSeen, isFalse);
    });

    test('the threshold sits clear of both cases', () {
      final open = LogCloudCoverage.analyse(logCloud());
      final capped = LogCloudCoverage.analyse(
        logCloud(capStart: true, capEnd: true),
      );

      // A margin either side, not a value that happens to work: the
      // threshold has to survive a real sensor's noisier sampling.
      expect(
        ScanCoverage.endFillThreshold,
        greaterThan(open.endFillStart + 0.05),
      );
      expect(
        ScanCoverage.endFillThreshold,
        lessThan(capped.endFillStart - 0.05),
      );
    });

    test('stray returns inside the trunk are not mistaken for an end', () {
      // Thirty loose points, no cut face. Judging occupancy one point at a
      // time this reads as a sawn end and lets the user finish a sweep that
      // never saw one -- the exact failure the flow exists to prevent, only
      // now dressed up as a passing check.
      final progress = LogCloudCoverage.analyse(
        logCloud(strayPointsPerEnd: 30),
      );

      final coverage = ScanCoverage(progress);

      expect(coverage.nearEndSeen, isFalse);
      expect(coverage.farEndSeen, isFalse);
    });

    test('it holds for a thin log as well as a thick one', () {
      for (final radius in [0.06, 0.2, 0.7]) {
        final capped = LogCloudCoverage.analyse(
          logCloud(radius: radius, capStart: true, capEnd: true),
        );

        expect(
          ScanCoverage(capped).nearEndSeen,
          isTrue,
          reason: "radius $radius",
        );
      }
    });
  });

  group('how far round the trunk has been seen', () {
    test('a full sweep round reads as full coverage', () {
      final progress = LogCloudCoverage.analyse(logCloud());

      expect(progress.angularCoverageDegrees, greaterThan(340));
    });

    test('one viewpoint cannot pass for a sweep', () {
      // A sensor standing still sees roughly 100-180 degrees of a cylinder.
      final progress = LogCloudCoverage.analyse(logCloud(arcDegrees: 170));

      expect(ScanCoverage(progress).girthCovered, isFalse);
    });

    test('a partial arc is never overstated', () {
      // The figure only has to be wrong in one direction. Reading high lets
      // a thin arc finish a scan, and a circle fitted to a thin arc is
      // exactly what puts centimetres of error into a radius -- which then
      // squares into the volume someone is paid on. Reading low only asks
      // for a few more seconds of walking.
      //
      // Measured, arc in against degrees out:
      //   90 -> 70   120 -> 80   170 -> 110   220 -> 200
      // Above the gate the fit is well conditioned and the margin closes
      // (270 -> 310), which is harmless: 270 degrees really is enough.
      for (final arc in [90.0, 120.0, 150.0, 170.0]) {
        final progress = LogCloudCoverage.analyse(logCloud(arcDegrees: arc));

        expect(
          progress.angularCoverageDegrees,
          lessThanOrEqualTo(arc),
          reason: "$arc degrees of arc read as more than it saw",
        );
      }
    });

    test('coverage rises with the arc actually swept', () {
      // Monotonic, so the read-out climbs as the user walks round rather
      // than wandering about and making them doubt it.
      var previous = -1.0;

      for (final arc in [90.0, 120.0, 170.0, 220.0, 270.0, 320.0, 360.0]) {
        final degrees = LogCloudCoverage
            .analyse(logCloud(arcDegrees: arc))
            .angularCoverageDegrees;

        expect(degrees, greaterThanOrEqualTo(previous), reason: "at $arc");
        previous = degrees;
      }
    });

    test('the gate lets a genuine sweep through', () {
      // The conservatism above is only acceptable if a real sweep still
      // clears the bar. Someone who has gone comfortably past three
      // quarters of the way round must not be told to keep going.
      final progress = LogCloudCoverage.analyse(logCloud(arcDegrees: 300));

      expect(ScanCoverage(progress).girthCovered, isTrue);
    });

    test('a thin arc cannot finish the scan', () {
      final progress = LogCloudCoverage.analyse(
        logCloud(arcDegrees: 150, capStart: true, capEnd: true),
      );

      expect(ScanCoverage(progress).isReady, isFalse);
      expect(ScanCoverage(progress).advice, ScanAdvice.goRoundTheSides);
    });
  });

  group('the whole decision, end to end', () {
    test('a properly swept log enables Finish', () {
      // Denser than the other clouds here: this is the one test that has to
      // clear the surface-detail bar as well, and 25k points is a real
      // requirement rather than a property of the synthetic sampling.
      final progress = LogCloudCoverage.analyse(
        logCloud(rings: 400, perRing: 96, capStart: true, capEnd: true),
      );

      final coverage = ScanCoverage(progress);

      expect(coverage.isReady, isTrue, reason: coverage.message);
      expect(coverage.advice, ScanAdvice.readyToFinish);
      expect(coverage.completion, 1.0);
    });

    test('the failure this whole change exists to prevent', () {
      // Walked the length, went round the sides, never pointed at either
      // cut face. The old code would have finished this the moment the
      // bounding box stopped growing, and reported a length short by
      // however much was never looked at.
      final progress = LogCloudCoverage.analyse(logCloud());

      final coverage = ScanCoverage(progress);

      expect(coverage.isReady, isFalse);
      expect(coverage.advice, ScanAdvice.showTheNearEnd);
      expect(coverage.message.toLowerCase(), contains("near"));
    });

    test('stopping halfway along is not mistaken for a short log', () {
      // Only the first half of a 4 m log was swept, and the far end is
      // therefore where the user stopped rather than where the log does.
      final progress = LogCloudCoverage.analyse(
        logCloud(length: 2.0, capStart: true),
      );

      final coverage = ScanCoverage(progress);

      expect(coverage.farEndSeen, isFalse);
      expect(coverage.isReady, isFalse);
    });
  });
}
