import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_measurement.dart';
import 'package:smartlog2/services/lidar_measurement_source.dart';
import 'package:smartlog2/services/lidar_scanner_service.dart';
import 'package:smartlog2/utils/measurement_scale.dart';
import 'package:vector_math/vector_math_64.dart';

/// A cylinder resting on a flat surface, sampled the way a depth sensor
/// samples: at a roughly fixed angular and axial step over the visible arc,
/// with the surface it stands on included.
///
/// The supporting surface is the whole point. A cylinder floating in empty
/// space is a case the old pipeline handled perfectly well; one standing on
/// a table is the case that broke it, because the flood fill stepped across
/// the contact line and measured the furniture.
({List<Vector3> cloud, Vector3 tap}) cylinderOnSurface({
  required double radius,
  required double length,
  double arcDegrees = 260,
  double sampleSpacing = 0.004,
  double surfaceExtent = 1.2,
  bool withSurface = true,
}) {
  final points = <Vector3>[];

  // Axis along Z, cylinder resting so its lowest surface touches y = 0.
  final centreY = radius;

  final axialSteps = math.max(8, (length / sampleSpacing).round());
  final arc = arcDegrees * math.pi / 180;
  final angularSteps = math.max(8, (arc * radius / sampleSpacing).round());

  for (var i = 0; i <= axialSteps; i++) {
    final z = length * i / axialSteps;

    for (var j = 0; j <= angularSteps; j++) {
      // Centred on straight up, so the visible arc is the top of the
      // cylinder -- where a sensor held above it actually looks.
      final theta = math.pi / 2 - arc / 2 + arc * j / angularSteps;

      points.add(
        Vector3(radius * math.cos(theta), centreY + radius * math.sin(theta), z),
      );
    }
  }

  if (withSurface) {
    final steps = math.max(4, (surfaceExtent / (sampleSpacing * 3)).round());

    for (var i = 0; i <= steps; i++) {
      for (var j = 0; j <= steps; j++) {
        points.add(
          Vector3(
            -surfaceExtent / 2 + surfaceExtent * i / steps,
            0,
            -surfaceExtent / 4 + (length + surfaceExtent / 2) * j / steps,
          ),
        );
      }
    }
  }

  // The tap lands on the top of the cylinder, halfway along -- where a user
  // aiming at the object would put it.
  return (
    cloud: points,
    tap: Vector3(0, centreY + radius, length / 2),
  );
}

void main() {
  group('reading the sensor rather than assuming the object', () {
    test('sample spacing is recovered from a regular grid', () {
      const spacing = 0.006;

      final grid = <Vector3>[
        for (var i = 0; i < 40; i++)
          for (var j = 0; j < 40; j++)
            Vector3(i * spacing, j * spacing, 0),
      ];

      expect(
        MeasurementScale.estimateSampleSpacing(grid),
        closeTo(spacing, spacing * 0.2),
      );
    });

    test('spacing is found at every scale, not just log scale', () {
      // The estimator must not have a working range of its own, or it
      // reintroduces exactly the assumption it exists to remove.
      for (final spacing in [0.0015, 0.004, 0.02]) {
        final grid = <Vector3>[
          for (var i = 0; i < 30; i++)
            for (var j = 0; j < 30; j++)
              Vector3(i * spacing, j * spacing, 0),
        ];

        expect(
          MeasurementScale.estimateSampleSpacing(grid),
          closeTo(spacing, spacing * 0.25),
          reason: "spacing $spacing",
        );
      }
    });

    test('degenerate clouds do not produce a zero tolerance', () {
      // A zero tolerance makes every point an outlier and every fit fail.
      for (final cloud in [
        <Vector3>[],
        [Vector3.zero()],
        [Vector3.zero(), Vector3.zero(), Vector3.zero()],
      ]) {
        final scale = MeasurementScale.fromCloud(cloud);

        expect(scale.inlierToleranceMetres, greaterThan(0));
        expect(scale.connectionRadiusMetres, greaterThan(0));
        expect(scale.slabThicknessMetres, greaterThan(0));
      }
    });
  });

  group('tolerances follow the object', () {
    test('a small object gets tolerances a small object can survive', () {
      final scene = cylinderOnSurface(radius: 0.03, length: 0.2);

      final scale = MeasurementScale.fromCloud(scene.cloud, near: scene.tap)
          .refinedFor(radiusMetres: 0.03, lengthMetres: 0.2);

      // The failure this fixes: an 8 cm reach on a 3 cm object.
      expect(scale.connectionRadiusMetres, lessThan(0.03));

      // And a 1 cm circle tolerance on a 3 cm radius, which admitted a
      // third of the object as inlier slack. It cannot go below the
      // sampling -- nothing can resolve finer than the sensor sampled --
      // but it must be a small share of the object rather than a third.
      expect(scale.inlierToleranceMetres, lessThan(0.03 * 0.15));
      expect(
        scale.inlierToleranceMetres,
        lessThan(MeasurementScale.maxInlierToleranceMetres),
      );

      // Enough sections to find the thin end rather than 10 slabs total.
      expect(0.2 / scale.slabThicknessMetres, greaterThan(20));
    });

    test('a real log is left at the tolerances it always had', () {
      // This change must only ever tighten. If it loosened anything, every
      // reading taken in a yard would move, and the yard is the case that
      // was already working.
      final scene =
          cylinderOnSurface(radius: 0.17, length: 3.0, sampleSpacing: 0.008);

      final scale = MeasurementScale.fromCloud(scene.cloud, near: scene.tap)
          .refinedFor(radiusMetres: 0.17, lengthMetres: 3.0);

      expect(
        scale.connectionRadiusMetres,
        lessThanOrEqualTo(MeasurementScale.maxConnectionRadiusMetres),
      );
      expect(
        scale.inlierToleranceMetres,
        lessThanOrEqualTo(MeasurementScale.maxInlierToleranceMetres),
      );
      expect(
        scale.slabThicknessMetres,
        lessThanOrEqualTo(MeasurementScale.maxSlabThicknessMetres),
      );
    });

    test('nonsense from a failed first pass is ignored', () {
      final scene = cylinderOnSurface(radius: 0.1, length: 1.0);
      final base = MeasurementScale.fromCloud(scene.cloud, near: scene.tap);

      for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          base.refinedFor(radiusMetres: bad, lengthMetres: 1.0).isRefined,
          isFalse,
          reason: "radius $bad",
        );
      }
    });
  });

  group('measuring the object and not the table it stands on', () {
    /// Runs the real pipeline end to end, exactly as the app does.
    LogMeasurement? measure(({List<Vector3> cloud, Vector3 tap}) scene) {
      return LidarMeasurementSource.measurementFrom(
        PointCloudCapture(
          points: scene.cloud,
          taps: [scene.tap],
          trackingState: "normal",
        ),
      );
    }

    test('a small cylinder measures its own size, not the table', () {
      // 6 cm across, 20 cm long -- the object the app was actually tested
      // against, and the size at which every fixed tolerance in the
      // pipeline was wrong by an order of magnitude.
      const radius = 0.03;
      const length = 0.20;

      final measurement = measure(
        cylinderOnSurface(radius: radius, length: length),
      );

      expect(measurement, isNotNull, reason: "nothing measured at all");

      final diameterMetres = measurement!.minDiameterInches * 0.0254;

      expect(
        diameterMetres,
        closeTo(radius * 2, radius * 2 * 0.15),
        reason: "measured ${(diameterMetres * 100).toStringAsFixed(1)} cm "
            "for a ${(radius * 200).toStringAsFixed(1)} cm cylinder",
      );
    });

    test('the length of a small object is not the length of the table', () {
      const length = 0.20;

      final measurement = measure(
        cylinderOnSurface(radius: 0.03, length: length),
      );

      final lengthMetres = measurement!.lengthFeet * 0.3048;

      expect(lengthMetres, closeTo(length, length * 0.2));
    });

    test('it still measures a full-size log correctly', () {
      // The regression that matters most: whatever this change does for a
      // mug, a log in a yard must read the same as it always did.
      const radius = 0.17;
      const length = 3.0;

      final measurement = measure(
        cylinderOnSurface(
          radius: radius,
          length: length,
          sampleSpacing: 0.008,
        ),
      );

      expect(measurement, isNotNull);

      final diameterMetres = measurement!.minDiameterInches * 0.0254;

      expect(diameterMetres, closeTo(radius * 2, radius * 2 * 0.1));
    });

    test('sizes across two orders of magnitude all read true', () {
      // One pipeline, no size it is secretly tuned for.
      for (final (radius, length) in [
        (0.025, 0.15),
        (0.05, 0.4),
        (0.10, 1.0),
        (0.20, 2.5),
      ]) {
        final measurement = measure(
          cylinderOnSurface(
            radius: radius,
            length: length,
            sampleSpacing: math.max(0.003, radius / 12),
          ),
        );

        expect(measurement, isNotNull, reason: "radius $radius: no reading");

        final diameterMetres = measurement!.minDiameterInches * 0.0254;

        expect(
          diameterMetres,
          closeTo(radius * 2, radius * 2 * 0.2),
          reason: "radius $radius: read "
              "${(diameterMetres / 2 * 100).toStringAsFixed(1)} cm radius",
        );
      }
    });
  });
}
