import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';

import '../models/log_measurement.dart';
import '../screens/lidar_capture_screen.dart';
import '../utils/log_geometry.dart';
import '../utils/log_volume_pipeline.dart';
import '../utils/point_cloud_segmenter.dart';
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
        "Tap the log once to choose it. The app separates it from the "
            "ground and from the logs beside it.",
        "Walk slowly from one end to the other, keeping the log in frame. "
            "The more of its curve you show the sensor, the tighter the "
            "girth.",
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

    if (capture == null || capture.taps.isEmpty) return null;

    return measurementInBackground(capture);
  }

  /// Runs [measurementFrom] off the UI thread.
  ///
  /// A sweep returns tens of thousands of points, and segmenting them means
  /// a RANSAC plane search plus a flood fill, then several passes of circle
  /// fitting on top. On the main isolate that is long enough to freeze the
  /// screen at exactly the moment the user is waiting to see their number.
  ///
  /// The cloud is copied into the worker isolate, which costs one memcpy of
  /// a megabyte or so -- far cheaper than the jank it avoids.
  static Future<LogMeasurement?> measurementInBackground(
    PointCloudCapture capture,
  ) =>
      compute(measurementFrom, capture);

  /// Turns a capture into a measurement.
  ///
  /// Separated from [measure] so it can be exercised directly against
  /// recorded point clouds from a real device, without any UI, and so the
  /// isolate above has a top-level function to call.
  static LogMeasurement? measurementFrom(PointCloudCapture capture) {
    if (capture.taps.isEmpty) return null;

    // One tap picks the log; the ground it rests on and the logs beside it
    // are separated out before any circle is fitted. Feeding the raw cloud
    // straight to buildProfile is what made scans read wrong: ground points
    // sit inside a slab as a flat sheet and drag the fitted radius out.
    final segmented = PointCloudSegmenter.segment(
      capture.points,
      capture.taps.first,
    );

    final List<Vector3> cloud;
    final Vector3 start;
    final Vector3 end;

    if (segmented.points.length >= 24) {
      final extent = LogGeometry.principalExtent(segmented.points);
      if (extent == null) return null;

      cloud = segmented.points;
      start = extent.start;
      end = extent.end;
    } else if (capture.taps.length >= 2) {
      // Segmentation found too little to work with -- fall back to the
      // user's own two taps rather than refusing to measure at all.
      cloud = capture.points;
      start = capture.taps.first;
      end = capture.taps[1];
    } else {
      return null;
    }

    final profile = LogGeometry.buildProfile(cloud, start, end);

    if (profile == null || profile.sections.isEmpty) return null;

    final minDiameterMetres = LogGeometry.minDiameterFromProfile(
      profile.diametersMetres,
    );

    if (minDiameterMetres == null || minDiameterMetres <= 0) return null;

    final meanResidualMetres = profile.meanResidualMetres ?? 0;

    // Girth comes from the traced outline where the scan supports it. The
    // thin end is chosen the same way the diameter is -- median-smoothed, so
    // one badly fitted slice cannot decide what the log is worth.
    final minPerimeterMetres = LogGeometry.medianSmoothedMinimum(
      profile.perimetersMetres,
    );

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
      tracedGirthInches: (minPerimeterMetres != null && minPerimeterMetres > 0)
          ? MeasurementUnits.metresToInches(minPerimeterMetres)
          : null,
    );
  }
}
