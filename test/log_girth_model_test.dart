import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/depth_frame.dart';
import 'package:smartlog2/utils/face_scan.dart';
import 'package:smartlog2/utils/log_girth_model.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';

/// The log in these tests runs along +x from the world origin. The near face
/// sits at x = 0 and faces back towards -x, which is where the user stood to
/// scan it; the camera then walks alongside, looking at the trunk from +z.
final Vector3 logAxis = Vector3(1, 0, 0);
final Vector3 nearNormal = Vector3(-1, 0, 0);

/// A face traced from a dense grid of points inside a known outline, exactly
/// as the scanner would trace one from a frame.
FaceScan faceFrom(
  double Function(double angle) outline, {
  Vector3? centre,
  Vector3? normal,
}) {
  final c = centre ?? Vector3.zero();
  final n = (normal ?? nearNormal).normalized();
  final basis = perpendicularBasis(n);

  final points = <Vector3>[];
  const step = 0.002;

  for (var a = -0.3; a <= 0.3; a += step) {
    for (var b = -0.3; b <= 0.3; b += step) {
      final radius = math.sqrt(a * a + b * b);
      var angle = math.atan2(b, a);
      if (angle < 0) angle += 2 * math.pi;

      if (radius <= outline(angle)) {
        points.add(c + basis.u * a + basis.v * b);
      }
    }
  }

  final traced = FaceScanner.traceOutline(
    points: points,
    centre: c,
    normal: n,
  )!;

  return FaceScan(
    centre: c,
    normal: n,
    distanceMetres: 0.6,
    tiltDegrees: 0,
    flatnessMm: 1,
    pointCount: points.length,
    outline: traced,
    touchesFrameEdge: false,
  );
}

/// A trunk reading as the profiler produces one: a width across the
/// sideways direction seen from +z, at a place along the log.
TrunkWidthSample reading(double along, double width) {
  return TrunkWidthSample(
    axialPosition: along,
    widthMetres: width,
    lateral: Vector3(0, 1, 0),
    centre: Vector3(along, 0, 0),
  );
}

/// Every stretch of trunk seen on several passes, as a real walk produces.
List<TrunkWidthSample> walk(
  double length,
  double Function(double along) width, {
  int passes = 3,
}) {
  final samples = <TrunkWidthSample>[];

  for (var pass = 0; pass < passes; pass++) {
    for (var t = 0.03; t < length; t += 0.06) {
      samples.add(reading(t, width(t)));
    }
  }

  return samples;
}

void main() {
  group('a round log', () {
    const radius = 0.15;
    const girth = 2 * math.pi * radius;
    final face = faceFrom((_) => radius);

    test('a trunk as wide as the face leaves the face girth standing', () {
      final model = LogGirthModel(
        nearFace: face,
        farFace: null,
        lengthMetres: 3,
        samples: walk(3, (_) => 2 * radius),
      );

      final minimum = model.minimumGirth;

      expect(minimum.girthMetres, closeTo(girth, 0.015 * girth));
      expect(minimum.source, GirthSource.nearEnd);
      expect(minimum.trunkSeen, isTrue);
    });

    test('a waist along the trunk is found and billed on', () {
      // Thins to 80% of its width over the middle metre.
      double width(double t) =>
          (t > 1.0 && t < 2.0) ? 2 * radius * 0.8 : 2 * radius;

      final model = LogGirthModel(
        nearFace: face,
        farFace: null,
        lengthMetres: 3,
        samples: walk(3, width),
      );

      final minimum = model.minimumGirth;

      expect(minimum.girthMetres, closeTo(girth * 0.8, 0.02 * girth));
      expect(minimum.source, GirthSource.trunk);
      expect(minimum.axialPosition, inInclusiveRange(1.0, 2.0));
    });

    test('one stray low reading does not set the price', () {
      final samples = walk(3, (_) => 2 * radius)
        ..add(reading(1.5, 2 * radius * 0.5))
        ..add(reading(1.5, 2 * radius * 0.5));

      final model = LogGirthModel(
        nearFace: face,
        farFace: null,
        lengthMetres: 3,
        samples: samples,
      );

      expect(model.minimumGirth.girthMetres, closeTo(girth, 0.02 * girth));
    });

    test('trunk noise alone never undercuts a scanned end', () {
      // Readings scattered 2% either side of the true width -- a thin spot
      // made of nothing but noise.
      final rng = math.Random(7);

      final model = LogGirthModel(
        nearFace: face,
        farFace: faceFrom(
          (_) => radius,
          centre: Vector3(3, 0, 0),
          normal: Vector3(1, 0, 0),
        ),
        lengthMetres: 3,
        samples: walk(3, (_) => 2 * radius * (1 + (rng.nextDouble() - 0.5) * 0.04)),
      );

      expect(model.minimumGirth.source, isNot(GirthSource.trunk));
    });
  });

  group('an oval log', () {
    // Wide way across along world z, narrow way along world y -- the side
    // the camera walks along sees the narrow way.
    const a = 0.18;
    const b = 0.12;

    double ellipse(double angle) {
      final c = math.cos(angle), s = math.sin(angle);
      return a * b / math.sqrt(b * b * c * c + a * a * s * s);
    }

    final face = faceFrom(ellipse);
    final trueGirth = truePerimeter(ellipse);

    test('the face knows how wide it is from the side the trunk is seen', () {
      expect(face.outline.widthAcross(Vector3(0, 1, 0)), closeTo(2 * b, 0.01));
    });

    test('a waist on an oval log is read as an oval girth, not a circle', () {
      final width = face.outline.widthAcross(Vector3(0, 1, 0))!;

      // The same oval, 85% the size, over the middle of the log.
      double trunk(double t) => (t > 0.8 && t < 1.7) ? width * 0.85 : width;

      final model = LogGirthModel(
        nearFace: face,
        farFace: null,
        lengthMetres: 2.5,
        samples: walk(2.5, trunk),
      );

      final girth = model.minimumGirth.girthMetres;

      expect(girth, closeTo(trueGirth * 0.85, 0.03 * trueGirth));

      // What assuming a round section would have billed on that waist --
      // short by more than a tenth.
      expect(math.pi * width * 0.85, lessThan(trueGirth * 0.85 * 0.92));
    });
  });

  group('a log that tapers from one end to the other', () {
    final near = faceFrom((_) => 0.16);
    final far = faceFrom(
      (_) => 0.12,
      centre: Vector3(3, 0, 0),
      normal: Vector3(1, 0, 0),
    );

    test('bills on the thin end when the trunk follows the taper', () {
      double width(double t) => 2 * (0.16 + (0.12 - 0.16) * (t / 3));

      final model = LogGirthModel(
        nearFace: near,
        farFace: far,
        lengthMetres: 3,
        samples: walk(3, width),
      );

      final minimum = model.minimumGirth;

      expect(
        minimum.girthMetres,
        closeTo(2 * math.pi * 0.12, 0.02 * 2 * math.pi * 0.12),
      );
      expect(minimum.source, GirthSource.farEnd);
    });

    test('with the far end unscanned, the trunk shows the taper', () {
      double width(double t) => 2 * (0.16 + (0.12 - 0.16) * (t / 3));

      final model = LogGirthModel(
        nearFace: near,
        farFace: null,
        lengthMetres: 3,
        samples: walk(3, width),
        farEndEstimated: true,
      );

      final minimum = model.minimumGirth;

      expect(minimum.source, GirthSource.trunk);
      expect(minimum.girthMetres, lessThan(2 * math.pi * 0.13));
    });

    test('reports both end girths as measured, not inferred', () {
      final model = LogGirthModel(
        nearFace: near,
        farFace: far,
        lengthMetres: 3,
        samples: const [],
      );

      final ends = model.profile.where((p) => !p.inferred).toList();

      expect(ends, hasLength(2));
      expect(model.faceGirthMetres, closeTo(2 * math.pi * 0.16, 0.02));
      expect(model.farFaceGirthMetres, closeTo(2 * math.pi * 0.12, 0.02));
    });
  });

  group('when the trunk could not be seen at all', () {
    test('the thinner end stands for the log', () {
      final model = LogGirthModel(
        nearFace: faceFrom((_) => 0.16),
        farFace: faceFrom(
          (_) => 0.13,
          centre: Vector3(3, 0, 0),
          normal: Vector3(1, 0, 0),
        ),
        lengthMetres: 3,
        samples: const [],
      );

      final minimum = model.minimumGirth;

      expect(minimum.girthMetres, closeTo(2 * math.pi * 0.13, 0.02));
      expect(minimum.source, GirthSource.farEnd);
      expect(minimum.trunkSeen, isFalse);
    });

    test('with only the near face, that face is the answer', () {
      final model = LogGirthModel(
        nearFace: faceFrom((_) => 0.14),
        farFace: null,
        lengthMetres: 2,
        samples: const [],
        farEndEstimated: true,
      );

      final minimum = model.minimumGirth;

      expect(minimum.girthMetres, closeTo(2 * math.pi * 0.14, 0.02));
      expect(minimum.source, GirthSource.nearEnd);
    });
  });

  group('reading the trunk out of a depth frame', () {
    const radius = 0.15;

    List<double> widthsAt(double subPixel) {
      // Shifting the principal point by a fraction of a pixel moves where the
      // pixel grid falls against the log's edge -- which is exactly what a
      // walking user's hand does from one frame to the next.
      final camera = SyntheticCamera(cy: 48 + subPixel, cx: 64 + subPixel);

      final frame = camera.frame(
        camera.renderCylinderSide(
          centre: Vector3(0, 0, -0.8),
          axis: logAxis,
          radius: radius,
        ),
      );

      return TrunkProfiler.sample(
        frame,
        origin: Vector3(-0.5, 0, -0.8),
        axis: logAxis,
        maxFaceWidthMetres: 2 * radius,
      ).map((s) => s.widthMetres).toList();
    }

    test('a round trunk reads its full diameter, on average over the hand',
        () {
      final widths = <double>[];

      for (final phase in [0.0, 0.2, 0.4, 0.6, 0.8]) {
        final atPhase = widthsAt(phase);
        expect(atPhase, isNotEmpty, reason: 'no slices at phase $phase');
        widths.addAll(atPhase);
      }

      final mean = widths.reduce((a, b) => a + b) / widths.length;

      expect(mean, closeTo(2 * radius, 0.015 * 2 * radius));

      for (final w in widths) {
        expect(w, closeTo(2 * radius, 0.04 * 2 * radius));
      }
    });

    test('the width is measured across the line of sight', () {
      final camera = SyntheticCamera();
      final frame = camera.frame(
        camera.renderCylinderSide(
          centre: Vector3(0, 0, -0.8),
          axis: logAxis,
          radius: radius,
        ),
      );

      final samples = TrunkProfiler.sample(
        frame,
        origin: Vector3(-0.5, 0, -0.8),
        axis: logAxis,
        maxFaceWidthMetres: 2 * radius,
      );

      for (final s in samples) {
        expect(s.lateral.dot(Vector3(0, 1, 0)).abs(), greaterThan(0.95));
      }
    });

    test('a thicker trunk reads thicker, from further away', () {
      final camera = SyntheticCamera();
      final frame = camera.frame(
        camera.renderCylinderSide(
          centre: Vector3(0, 0, -1.3),
          axis: logAxis,
          radius: 0.25,
        ),
      );

      final samples = TrunkProfiler.sample(
        frame,
        origin: Vector3(-0.5, 0, -1.3),
        axis: logAxis,
        maxFaceWidthMetres: 0.5,
      );

      expect(samples, isNotEmpty);

      final mean = samples.map((s) => s.widthMetres).reduce((a, b) => a + b) /
          samples.length;

      expect(mean, closeTo(0.5, 0.04 * 0.5));
    });

    test('samples can be restated once the true axis is known', () {
      final s = TrunkWidthSample(
        axialPosition: 1.0,
        widthMetres: 0.3,
        lateral: Vector3(0, 1, 0),
        centre: Vector3(1.2, 0, 0),
      );

      final restated = s.restatedAgainst(
        origin: Vector3(0.2, 0, 0),
        axis: logAxis,
      );

      expect(restated.axialPosition, closeTo(1.0, 1e-9));
      expect(restated.widthMetres, 0.3);
    });
  });
}
