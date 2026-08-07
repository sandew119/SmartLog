import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_measurement.dart';
import 'package:smartlog2/services/lidar_measurement_source.dart';
import 'package:smartlog2/services/lidar_scanner_service.dart';
import 'package:vector_math/vector_math_64.dart';

/// Builds a one-sided cylinder point cloud, as the sensor would see a log.
List<Vector3> cylinderCloud({
  required Vector3 start,
  required Vector3 end,
  required double radius,
  int sectionsAlong = 60,
  int pointsPerSection = 40,
  double visibleArcDegrees = 200,
}) {
  final axis = end - start;
  final length = axis.length;
  final direction = axis.normalized();

  final helper =
      direction.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
  final u = direction.cross(helper).normalized();
  final v = direction.cross(u).normalized();

  final span = visibleArcDegrees * math.pi / 180;
  final cloud = <Vector3>[];

  for (var i = 0; i < sectionsAlong; i++) {
    final along = (i / (sectionsAlong - 1)) * length;

    for (var j = 0; j < pointsPerSection; j++) {
      final angle = (j / (pointsPerSection - 1)) * span;

      cloud.add(
        start +
            direction * along +
            u * (radius * math.cos(angle)) +
            v * (radius * math.sin(angle)),
      );
    }
  }

  return cloud;
}

/// End-to-end over the part of the LiDAR path that is testable without a
/// device: a point cloud in, a finished measurement in trade units out.
/// Real clouds captured on-device can be dropped in here later as fixtures.
void main() {
  test('turns a synthetic cylinder into a measurement in inches and feet',
      () {
    // 0.25 m radius (0.5 m diameter ~= 19.7 in), 3 m long (~9.84 ft).
    final start = Vector3(0, 0, 2);
    final end = Vector3(0, 0, 5);

    final capture = PointCloudCapture(
      points: cylinderCloud(start: start, end: end, radius: 0.25),
      taps: [start, end],
      trackingState: "normal",
    );

    final measurement = LidarMeasurementSource.measurementFrom(capture)!;

    expect(measurement.source, MeasurementSourceKind.lidar);
    expect(measurement.minDiameterInches, closeTo(19.7, 1.0));
    expect(measurement.lengthFeet, closeTo(9.84, 0.6));

    // Provenance the audit trail depends on.
    expect(measurement.crossSectionCount, greaterThan(5));
    expect(measurement.diameterProfileInches, isNotNull);
    expect(measurement.diameterProfileInches!.length,
        measurement.crossSectionCount);
    expect(measurement.minAngularSpanDegrees, greaterThan(110));

    // A clean synthetic scan must be graded good, or the quality gate would
    // block perfectly valid measurements in the field.
    expect(measurement.quality, MeasurementQuality.good);
    expect(measurement.limitingFactorMessage, isNull);
  });

  test('grades a narrowly-visible log as unreliable rather than saving it',
      () {
    final start = Vector3(0, 0, 2);
    final end = Vector3(0, 0, 4);

    // Only 70 degrees of the surface visible -- far too little to fit.
    final capture = PointCloudCapture(
      points: cylinderCloud(
        start: start,
        end: end,
        radius: 0.25,
        visibleArcDegrees: 70,
      ),
      taps: [start, end],
      trackingState: "normal",
    );

    // Every section fails the angular gate, so there is nothing to measure.
    expect(LidarMeasurementSource.measurementFrom(capture), isNull);
  });

  test('returns null rather than throwing when the taps are incomplete', () {
    final capture = PointCloudCapture(
      points: cylinderCloud(
        start: Vector3(0, 0, 2),
        end: Vector3(0, 0, 4),
        radius: 0.2,
      ),
      taps: [Vector3(0, 0, 2)],
      trackingState: "normal",
    );

    expect(LidarMeasurementSource.measurementFrom(capture), isNull);
  });

  test('returns null on an empty cloud', () {
    final capture = PointCloudCapture(
      points: const [],
      taps: [Vector3(0, 0, 2), Vector3(0, 0, 4)],
      trackingState: "normal",
    );

    expect(LidarMeasurementSource.measurementFrom(capture), isNull);
  });
}
