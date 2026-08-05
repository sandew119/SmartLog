import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/log_geometry.dart';
import 'package:vector_math/vector_math_64.dart';

/// Points on an arc of a circle, as the sensor would see one side of a log.
List<Vector2> arcPoints({
  required double radius,
  required double spanDegrees,
  int count = 60,
  Vector2? center,
  double noiseSigma = 0,
  int seed = 7,
  double startAngleDegrees = 0,
}) {
  final c = center ?? Vector2.zero();
  final random = math.Random(seed);
  final span = spanDegrees * math.pi / 180;
  final start = startAngleDegrees * math.pi / 180;

  return List.generate(count, (i) {
    final t = count == 1 ? 0.0 : i / (count - 1);
    final angle = start + t * span;

    final r = noiseSigma == 0
        ? radius
        : radius + _gaussian(random) * noiseSigma;

    return Vector2(
      c.x + r * math.cos(angle),
      c.y + r * math.sin(angle),
    );
  });
}

double _gaussian(math.Random random) {
  // Box-Muller.
  final u1 = 1 - random.nextDouble();
  final u2 = random.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

/// A synthetic log: a cylinder along [axis] seen from one side, optionally
/// tapered so it has a genuine thin end.
List<Vector3> cylinderCloud({
  required Vector3 start,
  required Vector3 end,
  required double startRadius,
  double? endRadius,
  int sectionsAlong = 60,
  int pointsPerSection = 40,
  double visibleArcDegrees = 180,
  double noiseSigma = 0,
  int seed = 11,
}) {
  final random = math.Random(seed);
  final axis = (end - start);
  final length = axis.length;
  final direction = axis.normalized();

  final helper =
      direction.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
  final u = direction.cross(helper).normalized();
  final v = direction.cross(u).normalized();

  final cloud = <Vector3>[];
  final span = visibleArcDegrees * math.pi / 180;

  for (var i = 0; i < sectionsAlong; i++) {
    final t = i / (sectionsAlong - 1);
    final along = t * length;

    final radius = endRadius == null
        ? startRadius
        : startRadius + (endRadius - startRadius) * t;

    for (var j = 0; j < pointsPerSection; j++) {
      final angle = (j / (pointsPerSection - 1)) * span;
      final r =
          noiseSigma == 0 ? radius : radius + _gaussian(random) * noiseSigma;

      cloud.add(
        start +
            direction * along +
            u * (r * math.cos(angle)) +
            v * (r * math.sin(angle)),
      );
    }
  }

  return cloud;
}

void main() {
  group('fitCircleTaubin', () {
    test('recovers a full circle exactly', () {
      final points = arcPoints(radius: 0.25, spanDegrees: 360, count: 90);
      final fit = LogGeometry.fitCircleTaubin(points)!;

      expect(fit.radius, closeTo(0.25, 1e-6));
      expect(fit.center.x, closeTo(0, 1e-6));
      expect(fit.center.y, closeTo(0, 1e-6));
      expect(fit.rmsResidual, closeTo(0, 1e-6));
    });

    test('recovers an off-origin circle', () {
      final points = arcPoints(
        radius: 0.18,
        spanDegrees: 360,
        center: Vector2(1.5, -2.25),
      );
      final fit = LogGeometry.fitCircleTaubin(points)!;

      expect(fit.radius, closeTo(0.18, 1e-6));
      expect(fit.center.x, closeTo(1.5, 1e-6));
      expect(fit.center.y, closeTo(-2.25, 1e-6));
    });

    test(
        'stays accurate on a 180 degree arc -- the realistic case, since a '
        'sensor only sees the front of a log', () {
      final points = arcPoints(radius: 0.22, spanDegrees: 180, count: 60);
      final fit = LogGeometry.fitCircleTaubin(points)!;

      expect(fit.radius, closeTo(0.22, 1e-6));
    });

    test('stays within 1% on a 120 degree arc', () {
      final points = arcPoints(radius: 0.22, spanDegrees: 120, count: 50);
      final fit = LogGeometry.fitCircleTaubin(points)!;

      expect((fit.radius - 0.22).abs() / 0.22, lessThan(0.01));
    });

    test('tolerates realistic sensor noise on a half-visible log', () {
      // ~5mm noise, comparable to iPhone LiDAR at close range.
      final points = arcPoints(
        radius: 0.20,
        spanDegrees: 180,
        count: 80,
        noiseSigma: 0.005,
      );
      final fit = LogGeometry.fitCircleTaubin(points)!;

      // Volume goes as diameter squared, so 2% here is ~4% of volume.
      expect((fit.radius - 0.20).abs() / 0.20, lessThan(0.02));
    });

    test('returns null rather than throwing on degenerate input', () {
      expect(LogGeometry.fitCircleTaubin([]), isNull);
      expect(LogGeometry.fitCircleTaubin([Vector2(0, 0)]), isNull);
      expect(
        LogGeometry.fitCircleTaubin([Vector2(0, 0), Vector2(1, 1)]),
        isNull,
      );
    });

    test('does not return a bogus circle for perfectly collinear points', () {
      final collinear = List.generate(
        20,
        (i) => Vector2(i.toDouble(), 0),
      );

      final fit = LogGeometry.fitCircleTaubin(collinear);

      // Either it declines, or it reports a huge radius -- what it must
      // never do is return something that looks like a plausible log.
      if (fit != null) {
        expect(fit.radius, greaterThan(10));
      }
    });
  });

  group('angularSpan', () {
    test('reports the covered arc, not the full circle', () {
      final points = arcPoints(radius: 0.2, spanDegrees: 180, count: 40);
      final span = LogGeometry.angularSpan(points, Vector2.zero());

      expect(span * 180 / math.pi, closeTo(180, 6));
    });

    test('reports near 360 for a full circle', () {
      final points = arcPoints(radius: 0.2, spanDegrees: 360, count: 72);
      final span = LogGeometry.angularSpan(points, Vector2.zero());

      expect(span * 180 / math.pi, greaterThan(350));
    });

    test('reports a narrow value for a narrow arc', () {
      final points = arcPoints(radius: 0.2, spanDegrees: 60, count: 20);
      final span = LogGeometry.angularSpan(points, Vector2.zero());

      expect(span * 180 / math.pi, closeTo(60, 6));
    });
  });

  group('fitCircleRansac', () {
    test('ignores outliers from a neighbouring log', () {
      final points = arcPoints(
        radius: 0.20,
        spanDegrees: 180,
        count: 60,
        noiseSigma: 0.002,
      );

      // A second log's surface intruding into the same slab.
      points.addAll(
        arcPoints(
          radius: 0.15,
          spanDegrees: 90,
          count: 15,
          center: Vector2(0.55, 0),
        ),
      );

      final ransac = LogGeometry.fitCircleRansac(points, seed: 3)!;
      final plain = LogGeometry.fitCircleTaubin(points)!;

      // RANSAC must land near the true radius; the naive fit gets dragged.
      expect((ransac.radius - 0.20).abs(), lessThan(0.02));
      expect((ransac.radius - 0.20).abs(), lessThan((plain.radius - 0.20).abs()));
    });
  });

  group('minDiameterFromProfile', () {
    test('returns the minimum of a clean profile', () {
      expect(
        LogGeometry.minDiameterFromProfile([0.5, 0.45, 0.42, 0.44, 0.48]),
        closeTo(0.44, 1e-9),
      );
    });

    test(
        'a single bad section does not drag the answer down -- taking a raw '
        'min would undervalue the log', () {
      // 0.20 is a mis-fit outlier among otherwise consistent ~0.40 values.
      final smoothed = LogGeometry.minDiameterFromProfile(
        [0.40, 0.41, 0.20, 0.40, 0.42],
      )!;

      expect(smoothed, greaterThan(0.35));
    });

    test('still finds a genuine thin section', () {
      // Three consecutive low values are a real taper, not noise.
      final smoothed = LogGeometry.minDiameterFromProfile(
        [0.50, 0.48, 0.30, 0.30, 0.30, 0.47, 0.49],
      )!;

      expect(smoothed, closeTo(0.30, 1e-9));
    });

    test('handles empty and short profiles without throwing', () {
      expect(LogGeometry.minDiameterFromProfile([]), isNull);
      expect(LogGeometry.minDiameterFromProfile([0.33]), closeTo(0.33, 1e-9));
      expect(
        LogGeometry.minDiameterFromProfile([0.40, 0.30]),
        closeTo(0.30, 1e-9),
      );
    });
  });

  group('buildProfile', () {
    test('recovers the diameter of a clean straight cylinder', () {
      final start = Vector3(0, 0, 2);
      final end = Vector3(0, 0, 5);

      final cloud = cylinderCloud(
        start: start,
        end: end,
        startRadius: 0.22,
        visibleArcDegrees: 200,
      );

      final profile = LogGeometry.buildProfile(cloud, start, end, seed: 5)!;

      expect(profile.sections, isNotEmpty);

      final minDiameter =
          LogGeometry.minDiameterFromProfile(profile.diametersMetres)!;

      expect((minDiameter - 0.44).abs() / 0.44, lessThan(0.03));
    });

    test('finds the thin end of a tapered log', () {
      final start = Vector3(0, 0, 2);
      final end = Vector3(0, 0, 5);

      final cloud = cylinderCloud(
        start: start,
        end: end,
        startRadius: 0.30,
        endRadius: 0.20,
        visibleArcDegrees: 200,
      );

      final profile = LogGeometry.buildProfile(cloud, start, end, seed: 5)!;
      final minDiameter =
          LogGeometry.minDiameterFromProfile(profile.diametersMetres)!;

      // Should land near the thin end (0.40 diameter), not the average.
      expect(minDiameter, lessThan(0.46));
      expect(minDiameter, greaterThan(0.34));
    });

    test('survives an off-centre seed axis via axis refinement', () {
      final trueStart = Vector3(0, 0, 2);
      final trueEnd = Vector3(0, 0, 5);

      final cloud = cylinderCloud(
        start: trueStart,
        end: trueEnd,
        startRadius: 0.25,
        visibleArcDegrees: 220,
      );

      // The user's taps land on the log's surface, not its centreline, and
      // on opposite sides -- so the seed axis is noticeably tilted.
      final seedStart = trueStart + Vector3(0.25, 0, 0);
      final seedEnd = trueEnd + Vector3(-0.25, 0, 0);

      final profile =
          LogGeometry.buildProfile(cloud, seedStart, seedEnd, seed: 5)!;

      expect(profile.sections, isNotEmpty);

      final minDiameter =
          LogGeometry.minDiameterFromProfile(profile.diametersMetres)!;

      // Without refinement the oblique slices would inflate this well past
      // the 0.50 true diameter.
      expect((minDiameter - 0.50).abs() / 0.50, lessThan(0.10));
    });

    test('rejects sections that show too little of the log surface', () {
      final start = Vector3(0, 0, 2);
      final end = Vector3(0, 0, 4);

      // Only 60 degrees visible -- below the usable threshold everywhere.
      final cloud = cylinderCloud(
        start: start,
        end: end,
        startRadius: 0.25,
        visibleArcDegrees: 60,
      );

      final profile = LogGeometry.buildProfile(cloud, start, end, seed: 5)!;

      expect(profile.sections, isEmpty);
      expect(profile.rejectedSections, isNotEmpty);
    });

    test('reports the limiting angular span across accepted sections', () {
      final start = Vector3(0, 0, 2);
      final end = Vector3(0, 0, 4);

      final cloud = cylinderCloud(
        start: start,
        end: end,
        startRadius: 0.25,
        visibleArcDegrees: 200,
      );

      final profile = LogGeometry.buildProfile(cloud, start, end, seed: 5)!;

      expect(profile.minAngularSpanDegrees, isNotNull);
      expect(profile.minAngularSpanDegrees!, greaterThan(110));
      expect(profile.meanResidualMetres, isNotNull);
    });

    test('returns null rather than throwing on unusable input', () {
      final a = Vector3(0, 0, 1);
      final b = Vector3(0, 0, 2);

      expect(LogGeometry.buildProfile([], a, b), isNull);
      expect(
        LogGeometry.buildProfile(
          List.generate(50, (_) => Vector3(0, 0, 1)),
          a,
          a,
        ),
        isNull,
      );
    });

    test('handles a diagonal log, not just axis-aligned ones', () {
      final start = Vector3(1, 0.5, 2);
      final end = Vector3(2.4, 1.2, 4.1);

      final cloud = cylinderCloud(
        start: start,
        end: end,
        startRadius: 0.20,
        visibleArcDegrees: 220,
      );

      final profile = LogGeometry.buildProfile(cloud, start, end, seed: 5)!;
      final minDiameter =
          LogGeometry.minDiameterFromProfile(profile.diametersMetres)!;

      expect((minDiameter - 0.40).abs() / 0.40, lessThan(0.05));
    });
  });
}
