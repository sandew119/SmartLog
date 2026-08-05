import 'dart:convert';

/// Where a log's dimensions came from. Persisted so a disputed volume can
/// be audited later -- for a commercial product that's a requirement, not a
/// nicety.
enum MeasurementSourceKind { lidar, manual }

/// How much the app trusts a measurement. Drives whether a scan is
/// accepted silently, accepted with a warning, or refused outright.
enum MeasurementQuality { good, fair, poor }

/// A log's measured dimensions plus everything needed to judge how much to
/// trust them.
class LogMeasurement {
  /// The smallest diameter found along the log -- the "thinnest place"
  /// convention the trade uses.
  final double minDiameterInches;

  final double lengthFeet;

  /// Half-width of the uncertainty band on [minDiameterInches]. Null for
  /// manual entry, where there is no sensor uncertainty to report.
  final double? diameterToleranceInches;

  /// Every cross-section diameter measured along the log, thin end first.
  ///
  /// Stored in full (not just the minimum) so that if the trade convention
  /// ever changes -- e.g. to mid-length girth, which is what classical
  /// Hoppus actually uses -- historic logs can be recomputed without
  /// re-scanning them.
  final List<double>? diameterProfileInches;

  final int crossSectionCount;

  /// Mean radial residual of the circle fits, in millimetres. Higher means
  /// a rougher or noisier surface.
  final double? meanResidualMm;

  /// Smallest angular span of log surface seen by any accepted
  /// cross-section, in degrees. The sensor only sees the front of a log, so
  /// a narrow arc makes the circle fit ill-conditioned.
  final double? minAngularSpanDegrees;

  final MeasurementSourceKind source;

  const LogMeasurement({
    required this.minDiameterInches,
    required this.lengthFeet,
    required this.source,
    this.diameterToleranceInches,
    this.diameterProfileInches,
    this.crossSectionCount = 0,
    this.meanResidualMm,
    this.minAngularSpanDegrees,
  });

  /// Hand-typed dimensions. Quality is not scored -- the user asserted
  /// these, so there is nothing for the app to be uncertain about.
  factory LogMeasurement.manual({
    required double diameterInches,
    required double lengthFeet,
  }) {
    return LogMeasurement(
      minDiameterInches: diameterInches,
      lengthFeet: lengthFeet,
      source: MeasurementSourceKind.manual,
    );
  }

  // --- Quality thresholds -------------------------------------------------
  // Provisional values. They MUST be retuned from the on-device calibration
  // data described in ios/Runner/LidarScanner/README-VALIDATION.md; they are
  // deliberately gathered here so that retuning is a one-place edit.

  /// Below this arc, circle fitting is ill-conditioned and radius error
  /// grows non-linearly.
  static const double minUsableAngularSpanDegrees = 110;

  /// Comfortable arc -- roughly a clear view of the log's front half.
  static const double goodAngularSpanDegrees = 140;

  /// Too few usable slices to trust the minimum.
  static const int minUsableCrossSections = 5;

  /// Tolerance as a fraction of diameter. Volume goes as diameter squared,
  /// so a 5% diameter band is already a ~10% volume band.
  static const double goodToleranceFraction = 0.02;
  static const double maxUsableToleranceFraction = 0.05;

  MeasurementQuality get quality {
    if (source == MeasurementSourceKind.manual) {
      return MeasurementQuality.good;
    }

    if (minDiameterInches <= 0 || lengthFeet <= 0) {
      return MeasurementQuality.poor;
    }

    final span = minAngularSpanDegrees;
    if (span != null && span < minUsableAngularSpanDegrees) {
      return MeasurementQuality.poor;
    }

    if (crossSectionCount > 0 && crossSectionCount < minUsableCrossSections) {
      return MeasurementQuality.poor;
    }

    final tolerance = diameterToleranceInches;
    final toleranceFraction =
        tolerance == null ? null : tolerance / minDiameterInches;

    if (toleranceFraction != null &&
        toleranceFraction > maxUsableToleranceFraction) {
      return MeasurementQuality.poor;
    }

    if ((toleranceFraction != null &&
            toleranceFraction > goodToleranceFraction) ||
        (span != null && span < goodAngularSpanDegrees)) {
      return MeasurementQuality.fair;
    }

    return MeasurementQuality.good;
  }

  /// Plain-language reason the measurement isn't clean, so the user can fix
  /// their technique rather than just seeing a number they can't act on.
  String? get limitingFactorMessage {
    if (source == MeasurementSourceKind.manual) return null;
    if (quality == MeasurementQuality.good) return null;

    if (minDiameterInches <= 0 || lengthFeet <= 0) {
      return "Could not measure the log. Move closer and try again.";
    }

    final span = minAngularSpanDegrees;
    if (span != null && span < goodAngularSpanDegrees) {
      return "Only ${span.toStringAsFixed(0)}° of the log surface was "
          "visible. Stand square to the log so more of its curve is in view.";
    }

    if (crossSectionCount > 0 && crossSectionCount < minUsableCrossSections) {
      return "Too few usable slices along the log. Keep the whole length in "
          "frame and hold steadier.";
    }

    final tolerance = diameterToleranceInches;
    if (tolerance != null) {
      return "Diameter is uncertain by about "
          "±${tolerance.toStringAsFixed(1)} in. Move closer (0.7-1.5 m) and "
          "avoid direct sunlight.";
    }

    return "Measurement quality is low. Move closer and try again.";
  }

  /// Formatted diameter with its uncertainty band, e.g. "14.2 in ±0.3 in".
  String get diameterDisplay {
    final base = "${minDiameterInches.toStringAsFixed(1)} in";
    final tolerance = diameterToleranceInches;

    if (tolerance == null || tolerance <= 0) return base;

    return "$base ±${tolerance.toStringAsFixed(1)} in";
  }

  /// Encodes the profile for the `logs.diameterProfile` TEXT column.
  String? get encodedProfile {
    final profile = diameterProfileInches;
    if (profile == null || profile.isEmpty) return null;

    return jsonEncode(
      profile.map((d) => double.parse(d.toStringAsFixed(4))).toList(),
    );
  }

  static List<double>? decodeProfile(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return null;

      return decoded
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList(growable: false);
    } catch (_) {
      // Corrupt provenance must never break loading a saved log.
      return null;
    }
  }
}
