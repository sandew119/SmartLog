import 'package:flutter/material.dart';

import '../models/log_measurement.dart';
import '../screens/lidar_capture_screen.dart';
import '../utils/log_geometry.dart';
import '../utils/log_volume_pipeline.dart';
import 'lidar_scanner_service.dart';
import 'measurement_source.dart';

/// Measures a log from the iPhone's LiDAR depth stream.
///
/// Collects a point cloud from the native AR view, then does every piece of
/// geometry in Dart via [LogGeometry] -- circle fitting, axis refinement,
/// quality gates -- so the accuracy-critical logic stays testable off-device.
class LidarMeasurementSource implements MeasurementSource {
  const LidarMeasurementSource();

  @override
  String get label => "LiDAR scan";

  @override
  String get actionLabel => "Scan Log";

  @override
  List<String> get guidance => const [
        "Stand 0.7–1.5 m from the log and square to it, so the sensor sees "
            "as much of its curve as possible.",
        "Tap one end of the log, then the other.",
        "Avoid direct sunlight — it swamps the infrared sensor. Shade gives "
            "a far better reading.",
        "Wet or very dark bark reflects less; move closer if the reading "
            "comes back uncertain.",
      ];

  @override
  Future<bool> isSupported() => LidarScannerService.instance.isSupported();

  @override
  Future<LogMeasurement?> measure(BuildContext context) async {
    final capture = await Navigator.push<PointCloudCapture?>(
      context,
      MaterialPageRoute(builder: (_) => const LidarCaptureScreen()),
    );

    if (capture == null || capture.taps.length < 2) return null;

    return measurementFrom(capture);
  }

  /// Turns a capture into a measurement.
  ///
  /// Separated from [measure] so it can be exercised directly against
  /// recorded point clouds from a real device, without any UI.
  static LogMeasurement? measurementFrom(PointCloudCapture capture) {
    if (capture.taps.length < 2) return null;

    final profile = LogGeometry.buildProfile(
      capture.points,
      capture.taps.first,
      capture.taps[1],
    );

    if (profile == null || profile.sections.isEmpty) return null;

    final minDiameterMetres = LogGeometry.minDiameterFromProfile(
      profile.diametersMetres,
    );

    if (minDiameterMetres == null || minDiameterMetres <= 0) return null;

    final meanResidualMetres = profile.meanResidualMetres ?? 0;

    return LogMeasurement(
      minDiameterInches:
          MeasurementUnits.metresToInches(minDiameterMetres),
      lengthFeet: MeasurementUnits.metresToFeet(profile.lengthMetres),
      source: MeasurementSourceKind.lidar,
      // Residual is a radial spread; a diameter spans two radii, so the
      // band on the diameter is twice the per-surface residual.
      diameterToleranceInches:
          MeasurementUnits.metresToInches(meanResidualMetres * 2),
      diameterProfileInches: profile.diametersMetres
          .map(MeasurementUnits.metresToInches)
          .toList(growable: false),
      crossSectionCount: profile.sections.length,
      meanResidualMm: meanResidualMetres * 1000,
      minAngularSpanDegrees: profile.minAngularSpanDegrees,
    );
  }
}
