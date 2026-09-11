import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';

import '../models/log_measurement.dart';
import '../screens/log_scanner_screen.dart';
import '../utils/log_geometry.dart';
import '../utils/log_volume_pipeline.dart';
import '../utils/measurement_scale.dart';
import '../utils/point_cloud_segmenter.dart';
import 'lidar_scanner_service.dart';
import 'measurement_source.dart';

/// Measures a log from the iPhone's LiDAR depth stream.
///
/// The live scan is [LogScannerScreen]: one cut end, a walk, the other cut
/// end, with every piece of geometry in tested Dart. [measurementFrom] below
/// is the earlier whole-log point-cloud pipeline, kept because its circle
/// fitting still serves recorded clouds and its tests pin its behaviour.
class LidarMeasurementSource implements MeasurementSource {
  const LidarMeasurementSource();

  @override
  String get label => "LiDAR scan";

  @override
  String get actionLabel => "Scan Log";

  @override
  List<String> get guidance => const [
        "Stand about one step from the log's cut end and point the phone at "
            "it. Hold still — the app finds the end by itself and says when "
            "it is done.",
        "Walk to the other end, keeping the log in the middle of the screen.",
        "Point at the other cut end. The length is measured in a straight "
            "line from end to end.",
        "Shade works better than direct sun, which blinds the depth sensor.",
      ];

  @override
  Future<bool> isSupported() => LidarScannerService.instance.isSupported();

  @override
  Future<LogMeasurement?> measure(BuildContext context) {
    return Navigator.push<LogMeasurement?>(
      context,
      MaterialPageRoute(builder: (_) => const LogScannerScreen()),
    );
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

    // Tolerances come from the scene, not from an assumption about how big
    // the thing in front of the camera is.
    //
    // Everything below used to run at distances chosen for a log about 30 cm
    // thick: an 8 cm flood-fill radius, a 1 cm circle-fit tolerance, 2 cm
    // slabs. On a log those are sensible. On a small cylinder the flood fill
    // steps clean off the object onto whatever it is resting on, and the
    // circle fit admits a third of the object's own radius as inlier slack,
    // so what comes back is a confident measurement of the table.
    final scale = MeasurementScale.fromCloud(
      capture.points,
      near: capture.taps.first,
    );

    var profile = _segmentAndProfile(capture, scale);
    if (profile == null || profile.sections.isEmpty) return null;

    // Second pass, with every tolerance re-derived from what the first pass
    // found. The rough figures do not need to be right -- only the right
    // order of magnitude, which even a contaminated first pass gets -- and
    // the second pass is what has to be accurate.
    final roughDiameter =
        LogGeometry.medianSmoothedMinimum(profile.diametersMetres) ?? 0;

    if (roughDiameter > 0 && profile.lengthMetres > 0) {
      final refined = _segmentAndProfile(
        capture,
        scale.refinedFor(
          radiusMetres: roughDiameter / 2,
          lengthMetres: profile.lengthMetres,
        ),
        seedRadiusMetres: roughDiameter / 2,
      );

      // Only adopt the refined pass if it still resolved the object. A
      // tighter tolerance that finds far fewer usable sections has rejected
      // real surface, and the looser answer is then the honest one.
      if (refined != null &&
          refined.sections.length >= profile.sections.length ~/ 2 &&
          refined.sections.isNotEmpty) {
        profile = refined;
      }
    }

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
      minDiameterInches: MeasurementUnits.metresToInches(minDiameterMetres),
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

  /// One segmentation-and-fit pass at the given tolerances.
  ///
  /// Always starts from the original capture rather than from the previous
  /// pass's output, so a first pass that wrongly discarded part of the object
  /// cannot narrow what the second pass is allowed to see.
  static LogProfile? _segmentAndProfile(
    PointCloudCapture capture,
    MeasurementScale scale, {
    double? seedRadiusMetres,
  }) {
    // One tap picks the log; the ground it rests on and the logs beside it
    // are separated out before any circle is fitted. Feeding the raw cloud
    // straight to buildProfile is what made scans read wrong: ground points
    // sit inside a slab as a flat sheet and drag the fitted radius out.
    final segmented = PointCloudSegmenter.segment(
      capture.points,
      capture.taps.first,
      groundToleranceMetres: scale.groundToleranceMetres,
      connectionRadiusMetres: scale.connectionRadiusMetres,
      minGroundExtentMetres: scale.minGroundExtentMetres,
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

    return LogGeometry.buildProfile(
      cloud,
      start,
      end,
      slabThicknessMetres: scale.slabThicknessMetres,
      inlierToleranceMetres: scale.inlierToleranceMetres,
      seedRadiusMetres: seedRadiusMetres,
    );
  }
}
