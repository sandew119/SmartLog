import 'dart:math' as math;

import 'unit_display.dart';

/// What the scanner has actually seen so far.
///
/// Raw numbers from the native accumulator, before any judgement is applied.
class ScanProgress {
  final int pointCount;

  /// Length of the log along its own axis, in metres, as observed so far.
  final double axisLengthMetres;

  /// How much of the way round the trunk has been seen, in degrees, at the
  /// worst-covered section. A single viewpoint sees roughly 100-180 degrees
  /// of a cylinder; walking around raises it.
  final double angularCoverageDegrees;

  /// How full the cross-section is at each end of the observed span, 0..1.
  ///
  /// This is the measurement that tells "the log ends here" from "I stopped
  /// looking here", and nothing else in the payload can. Along the trunk the
  /// sensor only ever sees the curved surface, so points sit in a ring at
  /// roughly the trunk radius and the middle of the disc is empty. At a sawn
  /// end the whole face is visible, so the disc fills in. A high fill means
  /// a real end; a low one means the cloud simply stops there.
  final double endFillStart;
  final double endFillEnd;

  /// Occupancy along the axis, for the coverage bar. Any length.
  final List<int> axialBins;

  /// The object's radius as measured so far, in metres. Zero until there is
  /// enough surface to fit to.
  ///
  /// A running figure, not the final measurement -- that is fitted properly
  /// once the sweep ends. It is on screen because a scan with no numbers on
  /// it feels like waiting rather than measuring, and because a reading that
  /// is obviously wrong is worth seeing *during* the sweep rather than after
  /// it.
  final double radiusMetres;

  /// ARKit's own view of whether it is tracking properly.
  final bool trackingReliable;

  const ScanProgress({
    this.pointCount = 0,
    this.axisLengthMetres = 0,
    this.angularCoverageDegrees = 0,
    this.endFillStart = 0,
    this.endFillEnd = 0,
    this.axialBins = const [],
    this.radiusMetres = 0,
    this.trackingReliable = true,
  });

  /// Reads a native progress payload, defaulting anything missing.
  ///
  /// Defensive on purpose: the native side is the least verified part of
  /// this app, and a malformed payload must degrade the guidance rather than
  /// crash the scan someone is halfway through.
  factory ScanProgress.fromNative(Map<Object?, Object?> raw) {
    double number(String key) {
      final value = raw[key];
      if (value is! num) return 0;
      final result = value.toDouble();
      return result.isFinite ? result : 0;
    }

    final bins = raw["axialBins"];

    return ScanProgress(
      pointCount:
          raw["pointCount"] is num ? (raw["pointCount"] as num).toInt() : 0,
      axisLengthMetres: number("axisLengthMetres"),
      angularCoverageDegrees: number("angularCoverageDegrees"),
      endFillStart: number("endFillStart").clamp(0.0, 1.0),
      endFillEnd: number("endFillEnd").clamp(0.0, 1.0),
      axialBins: bins is List
          ? [
              for (final b in bins)
                if (b is num) b.toInt()
            ]
          : const [],
      radiusMetres: number("radiusMetres"),
      trackingReliable: raw["trackingState"] == "normal",
    );
  }
}

/// The one thing the user most needs to do next.
enum ScanAdvice {
  aimAtLog,
  moveCloser,
  walkTheLength,
  showTheNearEnd,
  showTheFarEnd,
  goRoundTheSides,
  holdSteady,
  readyToFinish,
}

/// Judges whether a sweep is good enough to measure from.
///
/// Separated from the screen and from the native module because this is the
/// decision that determines whether a volume is trustworthy, and it is the
/// only part of the LiDAR path that can be tested without a device.
///
/// The rule it enforces is that a scan is finished when the log has been
/// *observed*, not when the user has stopped moving. The previous version
/// ended the sweep once the bounding box stopped growing for 1.6 seconds,
/// which meant pausing to reposition, or circling the girth before walking
/// the length, ended the measurement early and silently.
class ScanCoverage {
  /// Below this a cross-section is a ring of bark rather than a sawn face.
  ///
  /// A log end fills its disc; the curved trunk never does. Measured against
  /// synthetic clouds the two cases come out at about 1.0 and 0.0, so this
  /// sits with a third of the range clear on either side -- room for a real
  /// sensor's noisier sampling, and for a face caught at an angle rather
  /// than square-on.
  static const double endFillThreshold = 0.35;

  /// A circle fitted to less of an arc than this is ill-conditioned: a few
  /// millimetres of depth noise become centimetres of radius, and radius
  /// error squares into volume error.
  static const double minAngularCoverageDegrees = 200;

  /// Enough surface for the per-section circle fits to average noise out,
  /// on an object of a given length.
  ///
  /// Scaled rather than fixed. A flat 25 000 is right for a 3 m trunk and
  /// impossible for a 20 cm sample: the requirement is really "enough points
  /// to cover the surface", and a short object simply has less surface. Held
  /// between a floor that guarantees every section has points to fit and the
  /// original figure, so a full-size log is asked for exactly what it always
  /// was.
  static int requiredPointsFor(double lengthMetres) {
    if (!lengthMetres.isFinite || lengthMetres <= 0) return minPointFloor;

    return (lengthMetres * pointsPerMetre)
        .clamp(minPointFloor.toDouble(), maxPointRequirement.toDouble())
        .round();
  }

  /// Enough that each of the 48 axial sections can hold points in most of
  /// its 36 sectors -- the density the coverage measure itself needs.
  static const int minPointFloor = 6000;

  /// Chosen so a 3 m log -- the size the old fixed requirement was written
  /// for -- lands on that requirement exactly, and everything shorter is
  /// asked for a proportionate share of it.
  static const int pointsPerMetre = 8500;

  /// What a full-size log has always been asked for.
  static const int maxPointRequirement = 25000;

  /// Shorter than this and there is not enough object for the sensor to
  /// resolve at all.
  ///
  /// This is a sensor limit, not a statement about logs. It used to be 1.0 m,
  /// which meant anything smaller than a metre could never finish a scan --
  /// the Finish button stayed dead for ever with no way for the user to
  /// discover why. Whether the thing being measured is log-shaped is decided
  /// by its proportions during the fit, which is the honest place for it.
  static const double minPlausibleLengthMetres = 0.10;

  const ScanCoverage(this.progress);

  final ScanProgress progress;

  /// Points this particular object needs before its surface is well enough
  /// sampled to fit circles to.
  int get requiredPoints => requiredPointsFor(progress.axisLengthMetres);

  bool get hasEnoughPoints => progress.pointCount >= requiredPoints;

  bool get isPlausibleLength =>
      progress.axisLengthMetres >= minPlausibleLengthMetres;

  bool get nearEndSeen => progress.endFillStart >= endFillThreshold;
  bool get farEndSeen => progress.endFillEnd >= endFillThreshold;
  bool get bothEndsSeen => nearEndSeen && farEndSeen;

  bool get girthCovered =>
      progress.angularCoverageDegrees >= minAngularCoverageDegrees;

  /// Whether a measurement taken now would be worth trusting.
  bool get isReady =>
      hasEnoughPoints &&
      isPlausibleLength &&
      bothEndsSeen &&
      girthCovered &&
      progress.trackingReliable;

  /// 0..1, for the progress ring.
  ///
  /// The *worst* of the requirements rather than an average: a sweep with
  /// magnificent girth coverage and one end unseen is not three-quarters
  /// finished, it is unfinished.
  double get completion {
    if (progress.pointCount == 0) return 0;

    final parts = <double>[
      progress.pointCount / requiredPoints,
      progress.axisLengthMetres / minPlausibleLengthMetres,
      progress.angularCoverageDegrees / minAngularCoverageDegrees,
      progress.endFillStart / endFillThreshold,
      progress.endFillEnd / endFillThreshold,
    ];

    return parts.map((p) => p.clamp(0.0, 1.0)).reduce(math.min);
  }

  /// What to tell the user to do next.
  ///
  /// One instruction at a time, in the order that unblocks the scan fastest:
  /// there is no point asking someone to walk further when the tracking has
  /// dropped out.
  ScanAdvice get advice {
    if (!progress.trackingReliable) return ScanAdvice.holdSteady;
    if (progress.pointCount == 0) return ScanAdvice.aimAtLog;

    if (!isPlausibleLength) return ScanAdvice.walkTheLength;

    // Ends before girth: an unseen end caps the length, and length error is
    // linear in volume while a slightly thin arc is not.
    if (!nearEndSeen) return ScanAdvice.showTheNearEnd;
    if (!farEndSeen) return ScanAdvice.showTheFarEnd;

    if (!girthCovered) return ScanAdvice.goRoundTheSides;
    if (!hasEnoughPoints) return ScanAdvice.moveCloser;

    return ScanAdvice.readyToFinish;
  }

  String get message => switch (advice) {
        ScanAdvice.aimAtLog => "Point the camera at the log",
        ScanAdvice.moveCloser =>
          "Move closer and sweep again, slowly — the surface is still thin",
        ScanAdvice.walkTheLength =>
          "Move along it end to end, keeping the whole thing in view",
        ScanAdvice.showTheNearEnd =>
          "Point straight at the near cut face and hold it there a moment",
        ScanAdvice.showTheFarEnd =>
          "Now the far cut face — point straight at it and hold",
        ScanAdvice.goRoundTheSides =>
          "Walk round it — only part of the way round has been seen",
        ScanAdvice.holdSteady => "Hold steady — the camera has lost its place",
        ScanAdvice.readyToFinish =>
          "The whole log has been covered. Tap Finish when you're ready.",
      };

  /// Short labels for the coverage read-out.
  List<({String label, bool done, String detail})> get checklist => [
        (
          label: "Length",
          done: isPlausibleLength,
          detail: "${progress.axisLengthMetres.toStringAsFixed(2)} m",
        ),
        (
          label: "Near end",
          done: nearEndSeen,
          detail: nearEndSeen ? "seen" : "not seen yet",
        ),
        (
          label: "Far end",
          done: farEndSeen,
          detail: farEndSeen ? "seen" : "not seen yet",
        ),
        (
          label: "Around the log",
          done: girthCovered,
          detail: "${progress.angularCoverageDegrees.round()}°",
        ),
        (
          label: "Surface detail",
          done: hasEnoughPoints,
          detail: "${(progress.pointCount / 1000).toStringAsFixed(1)}k "
              "of ${(requiredPoints / 1000).toStringAsFixed(0)}k",
        ),
      ];

  /// The size measured so far, in the units the user works in, or null
  /// until there is enough surface to say anything.
  ///
  /// Deliberately shown while sweeping. A scanner that displays nothing but
  /// a progress bar gives the user no way to tell that it has locked onto
  /// the pallet instead of the log until the very end, and no sense that
  /// the thing in their hands is measuring at all.
  String? get liveSize {
    if (progress.radiusMetres <= 0 || progress.axisLengthMetres <= 0) {
      return null;
    }

    final diameterInches =
        progress.radiusMetres * 2 / UnitDisplay.centimetresPerInch * 100;

    final lengthFeet = progress.axisLengthMetres / UnitDisplay.metresPerFoot;

    return "${UnitDisplay.across(diameterInches)}   across\n"
        "${UnitDisplay.length(lengthFeet)}   long";
  }

  /// Per-section coverage, 0..1, for a bar showing where the thin spots are.
  ///
  /// Normalised against a high percentile rather than the maximum, so one
  /// spot where the user lingered does not make everywhere else look bad.
  List<double> get axialCoverage {
    final bins = progress.axialBins;
    if (bins.isEmpty) return const [];

    final sorted = [...bins]..sort();
    final reference =
        sorted[(sorted.length * 0.8).floor().clamp(0, sorted.length - 1)];

    if (reference <= 0) return List<double>.filled(bins.length, 0);

    return [for (final b in bins) (b / reference).clamp(0.0, 1.0)];
  }
}
