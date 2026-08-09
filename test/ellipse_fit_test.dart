import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/ellipse_fit.dart';

/// Points sampled from a known ellipse, optionally over a partial arc --
/// which is the realistic case, since a tap traces the face the camera can
/// actually see.
List<Offset> ellipsePoints({
  required Offset centre,
  required double a,
  required double b,
  double rotation = 0,
  int count = 72,
  double arcDegrees = 360,
  double startDegrees = 0,
  double noiseSigma = 0,
  int seed = 7,
}) {
  final random = math.Random(seed);
  final arc = arcDegrees * math.pi / 180;
  final start = startDegrees * math.pi / 180;

  return List.generate(count, (i) {
    final t = count == 1 ? 0.0 : i / (count - 1);
    final angle = start + t * arc;

    var x = a * math.cos(angle);
    var y = b * math.sin(angle);

    if (noiseSigma > 0) {
      x += _gaussian(random) * noiseSigma;
      y += _gaussian(random) * noiseSigma;
    }

    final c = math.cos(rotation);
    final s = math.sin(rotation);

    return Offset(
      centre.dx + x * c - y * s,
      centre.dy + x * s + y * c,
    );
  });
}

double _gaussian(math.Random random) {
  final u1 = 1 - random.nextDouble();
  final u2 = random.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

void main() {
  group('Ellipse geometry', () {
    test('radiusAt returns the semi-axes along the axes', () {
      const e = Ellipse(
        centre: Offset.zero,
        semiMajor: 100,
        semiMinor: 60,
        rotation: 0,
      );

      expect(e.radiusAt(0), closeTo(100, 1e-9));
      expect(e.radiusAt(math.pi / 2), closeTo(60, 1e-9));
      expect(e.radiusAt(math.pi), closeTo(100, 1e-9));
    });

    test('radiusAt follows the rotation', () {
      final e = Ellipse(
        centre: Offset.zero,
        semiMajor: 100,
        semiMinor: 50,
        rotation: math.pi / 2,
      );

      // Major axis now points along +y.
      expect(e.radiusAt(math.pi / 2), closeTo(100, 1e-9));
      expect(e.radiusAt(0), closeTo(50, 1e-9));
    });

    test('a circle has equal radii in every direction', () {
      const e = Ellipse(
        centre: Offset(5, -3),
        semiMajor: 40,
        semiMinor: 40,
        rotation: 0.7,
      );

      for (var deg = 0; deg < 360; deg += 30) {
        expect(e.radiusAt(deg * math.pi / 180), closeTo(40, 1e-9));
      }
    });

    test('contains distinguishes inside from outside', () {
      const e = Ellipse(
        centre: Offset(100, 100),
        semiMajor: 50,
        semiMinor: 20,
        rotation: 0,
      );

      expect(e.contains(const Offset(100, 100)), isTrue);
      expect(e.contains(const Offset(145, 100)), isTrue);
      expect(e.contains(const Offset(155, 100)), isFalse);
      expect(e.contains(const Offset(100, 115)), isTrue);
      expect(e.contains(const Offset(100, 125)), isFalse);
    });

    test('trueDiameter is the major axis, not the mean', () {
      const e = Ellipse(
        centre: Offset.zero,
        semiMajor: 60,
        semiMinor: 30,
        rotation: 0,
      );

      // A round face seen at an angle: the minor axis is foreshortened, so
      // only the major axis still spans the real diameter.
      expect(e.trueDiameter, 120);
    });

    test('toPolygon produces points that lie on the ellipse', () {
      const e = Ellipse(
        centre: Offset(20, 30),
        semiMajor: 80,
        semiMinor: 45,
        rotation: 0.4,
      );

      for (final p in e.toPolygon(36)) {
        final d = p - e.centre;
        final c = math.cos(e.rotation);
        final s = math.sin(e.rotation);
        final u = (d.dx * c + d.dy * s) / e.semiMajor;
        final v = (-d.dx * s + d.dy * c) / e.semiMinor;

        expect(u * u + v * v, closeTo(1, 1e-9));
      }
    });
  });

  group('fitEllipseIrls - clean data', () {
    test('recovers a circle', () {
      final points = ellipsePoints(
        centre: const Offset(200, 150),
        a: 90,
        b: 90,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.centre.dx, closeTo(200, 0.5));
      expect(fit.centre.dy, closeTo(150, 0.5));
      expect(fit.semiMajor, closeTo(90, 0.5));
      expect(fit.semiMinor, closeTo(90, 0.5));
    });

    test('recovers an axis-aligned ellipse', () {
      final points = ellipsePoints(
        centre: const Offset(300, 220),
        a: 120,
        b: 70,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.centre.dx, closeTo(300, 0.5));
      expect(fit.centre.dy, closeTo(220, 0.5));
      expect(fit.semiMajor, closeTo(120, 0.5));
      expect(fit.semiMinor, closeTo(70, 0.5));
    });

    test('recovers a rotated ellipse, including its angle', () {
      const rotation = 35 * math.pi / 180;

      final points = ellipsePoints(
        centre: const Offset(150, 150),
        a: 110,
        b: 55,
        rotation: rotation,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.semiMajor, closeTo(110, 1.0));
      expect(fit.semiMinor, closeTo(55, 1.0));
      expect(fit.rotation, closeTo(rotation, 0.03));
    });

    test('semiMajor is always the longer axis, whatever the input', () {
      // Deliberately "portrait": the long axis is vertical.
      final points = ellipsePoints(
        centre: const Offset(100, 100),
        a: 40,
        b: 95,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.semiMajor, greaterThan(fit.semiMinor));
      expect(fit.semiMajor, closeTo(95, 1.0));
      expect(fit.semiMinor, closeTo(40, 1.0));
    });

    test('rotation is normalised into [0, pi)', () {
      for (final deg in [10, 80, 100, 170]) {
        final points = ellipsePoints(
          centre: const Offset(100, 100),
          a: 90,
          b: 50,
          rotation: deg * math.pi / 180,
        );

        final fit = fitEllipseIrls(points)!;

        expect(fit.rotation, greaterThanOrEqualTo(0));
        expect(fit.rotation, lessThan(math.pi));
      }
    });
  });

  group('fitEllipseIrls - noise and outliers', () {
    test('tolerates realistic edge-detection noise', () {
      final points = ellipsePoints(
        centre: const Offset(250, 200),
        a: 100,
        b: 75,
        noiseSigma: 3,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.semiMajor, closeTo(100, 5));
      expect(fit.semiMinor, closeTo(75, 5));
      expect((fit.centre - const Offset(250, 200)).distance, lessThan(5));
    });

    test(
        'rejects gross outliers -- the whole reason this is robust rather '
        'than plain least squares', () {
      final points = ellipsePoints(
        centre: const Offset(200, 200),
        a: 100,
        b: 80,
        count: 60,
        noiseSigma: 1.5,
      );

      // A quarter of the rays land on background, shadow or a branch stub
      // far outside the face.
      final random = math.Random(3);
      for (var i = 0; i < 20; i++) {
        points.add(
          Offset(
            200 + (random.nextDouble() - 0.5) * 700,
            200 + (random.nextDouble() - 0.5) * 700,
          ),
        );
      }

      final robust = fitEllipseIrls(points)!;

      expect(robust.semiMajor, closeTo(100, 12));
      expect(robust.semiMinor, closeTo(80, 12));
      expect((robust.centre - const Offset(200, 200)).distance, lessThan(15));
    });

    test(
        'a near-circle with pixel quantisation still fits -- rotation is '
        'degenerate for a circle and must not blow the fit up', () {
      // Exactly what the detector produces: edges found at whole-pixel
      // radii around an almost round face. The tiny departure from circular
      // leaves the rotation parameter nearly unconstrained, which is the
      // case that used to diverge and return null.
      final points = <Offset>[
        for (var i = 0; i < 72; i++)
          Offset(
            (200 + 120 * math.cos(2 * math.pi * i / 72)).roundToDouble(),
            (200 + 120 * math.sin(2 * math.pi * i / 72)).roundToDouble(),
          ),
      ];

      final fit = fitEllipseIrls(points);

      expect(fit, isNotNull, reason: "a near-circle must still fit");
      expect(fit!.semiMajor, closeTo(120, 3));
      expect(fit.semiMinor, closeTo(120, 3));
      expect((fit.centre - const Offset(200, 200)).distance, lessThan(3));
    });

    test('a perfect circle fits without the rotation running away', () {
      final points = ellipsePoints(
        centre: const Offset(150, 150),
        a: 80,
        b: 80,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.semiMajor, closeTo(80, 0.5));
      expect(fit.semiMinor, closeTo(80, 0.5));
      // Whatever angle it reports is arbitrary for a circle, but it must be
      // a real number in range rather than a diverged one.
      expect(fit.rotation, greaterThanOrEqualTo(0));
      expect(fit.rotation, lessThan(math.pi));
    });

    test('a handful of stray points barely move the answer', () {
      final clean = ellipsePoints(
        centre: const Offset(180, 160),
        a: 90,
        b: 60,
      );

      final withStrays = [
        ...clean,
        const Offset(600, 600),
        const Offset(-300, 40),
        const Offset(180, 900),
      ];

      final a = fitEllipseIrls(clean)!;
      final b = fitEllipseIrls(withStrays)!;

      expect((a.centre - b.centre).distance, lessThan(6));
      expect((a.semiMajor - b.semiMajor).abs(), lessThan(6));
    });
  });

  group('fitEllipseIrls - partial arcs', () {
    test('fits from a 270-degree arc', () {
      final points = ellipsePoints(
        centre: const Offset(200, 200),
        a: 100,
        b: 70,
        arcDegrees: 270,
        count: 54,
      );

      final fit = fitEllipseIrls(points)!;

      expect(fit.semiMajor, closeTo(100, 6));
      expect(fit.semiMinor, closeTo(70, 6));
    });

    test('still returns something sane from a 180-degree arc', () {
      final points = ellipsePoints(
        centre: const Offset(200, 200),
        a: 100,
        b: 70,
        arcDegrees: 180,
        count: 40,
      );

      final fit = fitEllipseIrls(points);

      // Half an ellipse is enough to constrain one, but it is the hardest
      // realistic case, so this only asserts it stays in the right ballpark
      // rather than pretending to precision it cannot have.
      expect(fit, isNotNull);
      expect(fit!.semiMajor, closeTo(100, 25));
      expect(fit.semiMinor, closeTo(70, 25));
    });
  });

  group('fitEllipseIrls - degenerate input returns null, never nonsense', () {
    test('too few points', () {
      expect(fitEllipseIrls([]), isNull);
      expect(
        fitEllipseIrls(const [
          Offset(0, 0),
          Offset(1, 1),
          Offset(2, 0),
          Offset(3, 1),
        ]),
        isNull,
      );
    });

    test('perfectly collinear points', () {
      final line = List.generate(20, (i) => Offset(i.toDouble(), 0));

      // There is no ellipse through a straight line; returning one would be
      // an infinitely thin sliver that the packing engine would then trust.
      expect(fitEllipseIrls(line), isNull);
    });

    test('all points identical', () {
      final same = List.filled(12, const Offset(50, 50));
      expect(fitEllipseIrls(same), isNull);
    });

    test('non-finite coordinates', () {
      final points = ellipsePoints(
        centre: const Offset(100, 100),
        a: 50,
        b: 40,
      )..add(const Offset(double.nan, 10));

      expect(fitEllipseIrls(points), isNull);
    });
  });

  group('round trip into the packing engine', () {
    test('toOutline gives a polygon whose area matches the ellipse', () {
      const e = Ellipse(
        centre: Offset(200, 200),
        semiMajor: 100,
        semiMinor: 60,
        rotation: 0.3,
      );

      final outline = e.toOutline(segments: 180);

      // A 180-gon under-fills the true ellipse very slightly.
      expect(outline.area, closeTo(e.area, e.area * 0.001));
      expect(outline.points.length, 180);
    });

    test('a fitted circle produces an outline the engine can pack', () {
      final points = ellipsePoints(
        centre: const Offset(150, 150),
        a: 100,
        b: 100,
      );

      final outline = fitEllipseIrls(points)!.toOutline();

      expect(outline.isValid, isTrue);
      expect(outline.equivalentCircleDiameter, closeTo(200, 2));
    });
  });
}
