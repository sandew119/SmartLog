import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/log_geometry.dart';
import 'package:vector_math/vector_math_64.dart';

/// Points around a closed shape whose radius varies with angle.
List<Vector2> shape({
  required double Function(double angle) radiusAt,
  Vector2? center,
  int count = 360,
  double fromAngle = 0,
  double toAngle = 2 * math.pi,
  double noise = 0,
  int seed = 7,
}) {
  final origin = center ?? Vector2.zero();
  final random = math.Random(seed);
  final points = <Vector2>[];

  for (var i = 0; i < count; i++) {
    final angle = fromAngle + (toAngle - fromAngle) * i / count;
    final jitter = noise == 0 ? 0.0 : (random.nextDouble() - 0.5) * 2 * noise;
    final radius = radiusAt(angle) + jitter;

    points.add(
      Vector2(
        origin.x + radius * math.cos(angle),
        origin.y + radius * math.sin(angle),
      ),
    );
  }

  return points;
}

void main() {
  group('tracePerimeter', () {
    test('a fully observed round log traces to exactly pi * d', () {
      const radius = 0.15;
      final points = shape(radiusAt: (_) => radius);

      final trace = LogGeometry.tracePerimeter(
        points,
        Vector2.zero(),
        radius,
      );

      expect(trace, isNotNull);
      // The chord correction exists precisely so this is exact, not merely
      // close: a round log must not be penalised for being traced.
      expect(trace!.perimeter, closeTo(2 * math.pi * radius, 1e-6));
      expect(trace.observedFraction, closeTo(1.0, 1e-9));
    });

    test('an oval log traces longer than the circle through its fit', () {
      // A real log is never round. This is the whole reason for tracing:
      // a tape follows the long way around and reads more than pi*d.
      const major = 0.18;
      const minor = 0.12;

      final points = shape(
        radiusAt: (a) => major * minor /
            math.sqrt(
              math.pow(minor * math.cos(a), 2) +
                  math.pow(major * math.sin(a), 2),
            ),
      );

      final fit = LogGeometry.fitCircleTaubin(points);
      expect(fit, isNotNull);

      final trace = LogGeometry.tracePerimeter(
        points,
        fit!.center,
        fit.radius,
      );

      expect(trace, isNotNull);
      expect(trace!.perimeter, greaterThan(2 * math.pi * fit.radius));

      // Ramanujan's approximation is exact enough to be a reference here.
      const h = (major - minor) * (major - minor) /
          ((major + minor) * (major + minor));
      final ramanujan = math.pi *
          (major + minor) *
          (1 + 3 * h / (10 + math.sqrt(4 - 3 * h)));

      expect(trace.perimeter, closeTo(ramanujan, ramanujan * 0.01));
    });

    test('an unobserved arc is completed from the fitted circle', () {
      const radius = 0.15;

      // Only the front 180 degrees seen, as a single viewpoint would.
      final points = shape(
        radiusAt: (_) => radius,
        toAngle: math.pi,
        count: 180,
      );

      final trace = LogGeometry.tracePerimeter(
        points,
        Vector2.zero(),
        radius,
      );

      expect(trace, isNotNull);
      expect(trace!.perimeter, closeTo(2 * math.pi * radius, 1e-6));
      expect(trace.observedFraction, closeTo(0.5, 0.05));
    });

    test('reports how much of the section was actually seen', () {
      const radius = 0.15;

      final quarter = LogGeometry.tracePerimeter(
        shape(
          radiusAt: (_) => radius,
          toAngle: math.pi / 2,
          count: 120,
        ),
        Vector2.zero(),
        radius,
      );

      expect(quarter!.observedFraction, closeTo(0.25, 0.05));
    });

    test('a single bark flake cannot push the traced girth out', () {
      const radius = 0.15;

      final points = shape(radiusAt: (_) => radius);
      final clean = LogGeometry.tracePerimeter(
        points,
        Vector2.zero(),
        radius,
      )!;

      // One bin's worth of samples sitting proud of the surface.
      final flaked = [...points];
      for (var i = 0; i < 3; i++) {
        flaked.add(Vector2(radius * 1.3, 0.001 * i));
      }

      final traced = LogGeometry.tracePerimeter(
        flaked,
        Vector2.zero(),
        radius,
      )!;

      // The median in that bin holds, so the reading barely moves.
      expect(traced.perimeter, closeTo(clean.perimeter, clean.perimeter * 0.01));
    });

    test('survives surface noise without inflating the girth', () {
      const radius = 0.15;

      final trace = LogGeometry.tracePerimeter(
        shape(radiusAt: (_) => radius, noise: 0.003, count: 720),
        Vector2.zero(),
        radius,
      );

      expect(trace, isNotNull);
      // Noise must not systematically lengthen the tape: a jittered round
      // log still reads as a round log to within a percent.
      expect(
        trace!.perimeter,
        closeTo(2 * math.pi * radius, 2 * math.pi * radius * 0.01),
      );
    });

    test('refuses to trace a section too sparse to be meaningful', () {
      expect(
        LogGeometry.tracePerimeter(
          [Vector2(0.15, 0), Vector2(0, 0.15), Vector2(-0.15, 0)],
          Vector2.zero(),
          0.15,
        ),
        isNull,
      );
    });

    test('rejects a degenerate fitted radius rather than dividing by it', () {
      expect(
        LogGeometry.tracePerimeter(
          shape(radiusAt: (_) => 0.15),
          Vector2.zero(),
          0,
        ),
        isNull,
      );
    });
  });

  group('girth from a traced profile', () {
    test('an out-of-round log bills higher traced than assumed round', () {
      // The end-to-end consequence, stated in trade terms: assuming a
      // circle quietly undercharges for every log that is not one.
      const major = 0.18;
      const minor = 0.12;

      final points = shape(
        radiusAt: (a) => major * minor /
            math.sqrt(
              math.pow(minor * math.cos(a), 2) +
                  math.pow(major * math.sin(a), 2),
            ),
      );

      final fit = LogGeometry.fitCircleTaubin(points)!;
      final trace = LogGeometry.tracePerimeter(points, fit.center, fit.radius)!;

      final assumedGirth = 2 * math.pi * fit.radius;

      expect(trace.perimeter, greaterThan(assumedGirth));
    });

    test('medianSmoothedMinimum picks the thin end, not the worst fit', () {
      // One rogue slice must not decide the billed girth. The 0.40 here is
      // a slice that fitted badly; smoothing must discard it and settle on
      // the genuine thin end rather than undervaluing the log by two thirds.
      final perimeters = <double>[1.20, 1.19, 0.40, 1.18, 1.17, 1.16];

      final smoothed = LogGeometry.medianSmoothedMinimum(perimeters)!;

      expect(smoothed, greaterThan(1.0));
      expect(smoothed, closeTo(1.17, 1e-9));
    });
  });
}
