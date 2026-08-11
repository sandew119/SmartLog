import 'dart:ui' show Offset, Rect;

import 'package:image/image.dart' as img;

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';

/// One thing the model found.
///
/// Deliberately carries a [Rect] rather than a circle, even though the app's
/// [LogDefect] is circular. A classifier reports one finding covering the
/// whole image; an object detector reports several boxes. Both fit this, so
/// moving from ResNet to YOLO changes the detector and nothing else.
class DefectFinding {
  /// The class the model chose, mapped onto the app's own vocabulary.
  final LogDefectKind kind;

  /// The raw label the model emitted, kept for display and for debugging a
  /// mapping that turns out to be wrong.
  final String rawLabel;

  /// 0..1.
  final double confidence;

  /// Where it is, in image pixels. For a whole-image classifier this is the
  /// whole image.
  final Rect region;

  /// True when the model reports the surface is sound. Kept as a finding
  /// rather than an empty list, because "I looked and it is fine" and "I did
  /// not look" must not appear the same to the user.
  final bool isHealthy;

  const DefectFinding({
    required this.kind,
    required this.rawLabel,
    required this.confidence,
    required this.region,
    this.isHealthy = false,
  });

  /// Below this the specification says a prediction is uncertain, and the
  /// cutting engine will not route boards around it.
  static const double confidenceThreshold = 0.60;

  bool get isConfident => confidence >= confidenceThreshold;

  /// The app-native form, in the same coordinate space as the outline.
  ///
  /// A box becomes the circle that covers it, which is the shape the packing
  /// engine tests against. Slightly generous by design: a board that clips
  /// the edge of a rotten patch is not a board anyone wants.
  LogDefect toDefect() {
    return LogDefect(
      kind: kind,
      centre: region.center,
      radius: region.longestSide / 2,
      confidence: confidence,
      automatic: true,
    );
  }
}

/// Everything one run of the model produced.
class DefectAnalysis {
  final List<DefectFinding> findings;

  /// Per-class probability, so the UI can show that the model was torn
  /// between rot and a shadow rather than only showing the winner.
  final Map<String, double> scores;

  /// Where the model was looking, 0..1 per cell, row-major.
  ///
  /// A class activation map. Null when the detector cannot produce one --
  /// an object detector does not need to, because its boxes already say
  /// where it looked.
  final List<double>? activation;
  final int activationWidth;
  final int activationHeight;

  final int inferenceMs;

  const DefectAnalysis({
    this.findings = const [],
    this.scores = const {},
    this.activation,
    this.activationWidth = 0,
    this.activationHeight = 0,
    this.inferenceMs = 0,
  });

  bool get isClean => findings.isEmpty || findings.every((f) => f.isHealthy);

  /// Only the findings the engine is allowed to act on.
  List<DefectFinding> get actionable => [
        for (final f in findings)
          if (!f.isHealthy && f.isConfident) f
      ];

  /// True when the model answered but was not sure enough to act.
  bool get isUncertain => findings.isNotEmpty && !isClean && actionable.isEmpty;
}

/// Finds flaws on a log's cut face.
///
/// An interface with a deliberately boring default. Everything downstream --
/// the toggle, the packing engine, the result screen, the report -- is
/// written against this, so dropping in a real model is one line at the call
/// site and changes nothing else.
///
/// The user-facing feature works regardless, because a defect marked by hand
/// and a defect found by a model are the same [LogDefect] to everything that
/// consumes them.
abstract class DefectDetector {
  /// Human-readable, for the screen to say what is actually running.
  String get name;

  /// False until a model is installed. The UI uses this to decide whether to
  /// offer automatic scanning at all, rather than showing a button that
  /// always finds nothing.
  bool get isAvailable;

  Future<void> load();

  Future<DefectAnalysis> analyse(img.Image image);

  /// Convenience for callers that only want defects in outline space.
  Future<List<LogDefect>> detect({
    required img.Image image,
    required LogFaceOutline outline,
  }) async {
    final analysis = await analyse(image);
    return [for (final f in analysis.actionable) f.toDefect()];
  }

  void dispose() {}
}

/// The default: finds nothing, and says so honestly.
class NoAutomaticDefectDetector implements DefectDetector {
  const NoAutomaticDefectDetector();

  @override
  String get name => "No model installed";

  @override
  bool get isAvailable => false;

  @override
  Future<void> load() async {}

  @override
  Future<DefectAnalysis> analyse(img.Image image) async =>
      const DefectAnalysis();

  @override
  Future<List<LogDefect>> detect({
    required img.Image image,
    required LogFaceOutline outline,
  }) async =>
      const [];

  @override
  void dispose() {}
}

/// Maps whatever the model calls a class onto the app's own vocabulary.
///
/// Kept apart from the detector because the mapping is a property of the
/// *dataset*, not of the inference code: retraining on differently-named
/// folders changes this table and nothing else.
class DefectLabelMap {
  const DefectLabelMap._();

  /// Anything a model might reasonably emit, lowercased, against the kind
  /// the app understands. Unknown labels are not guessed at -- see
  /// [resolve].
  static const Map<String, LogDefectKind> _known = {
    "knot": LogDefectKind.knot,
    "knots": LogDefectKind.knot,
    "live_knot": LogDefectKind.knot,
    "dead_knot": LogDefectKind.knot,
    "rot": LogDefectKind.rot,
    "rotten": LogDefectKind.rot,
    "decay": LogDefectKind.rot,
    "blue_stain": LogDefectKind.rot,
    "stain": LogDefectKind.rot,
    "crack": LogDefectKind.crack,
    "cracks": LogDefectKind.crack,
    "split": LogDefectKind.crack,
    "checks": LogDefectKind.crack,
    "shake": LogDefectKind.shake,
    "hole": LogDefectKind.hollow,
    "holes": LogDefectKind.hollow,
    "hollow": LogDefectKind.hollow,
    "wormhole": LogDefectKind.hollow,
    "marrow": LogDefectKind.hollow,
  };

  /// Labels meaning "nothing wrong here".
  static const Set<String> healthyLabels = {
    "healthy",
    "normal",
    "sound",
    "clear",
    "good",
    "no_defect",
    "nodefect",
    "none",
  };

  static bool isHealthy(String label) =>
      healthyLabels.contains(_normalise(label));

  static String _normalise(String label) =>
      label.trim().toLowerCase().replaceAll(RegExp(r"[\s\-]+"), "_");

  /// The kind a label means, or null when the label is not recognised.
  ///
  /// Null rather than a default: silently filing an unknown class under
  /// "knot" would let a mapping mistake reach a cutting plan disguised as a
  /// real finding. The caller shows the raw label instead and treats it as
  /// something to look at by eye.
  static LogDefectKind? resolve(String label) {
    final key = _normalise(label);

    if (healthyLabels.contains(key)) return null;
    if (_known.containsKey(key)) return _known[key];

    // "dead_knot_with_crack" and the like: fall back to whichever known
    // term appears, most severe first, so a compound label is never worse
    // than unmapped.
    for (final kind in [
      LogDefectKind.hollow,
      LogDefectKind.rot,
      LogDefectKind.shake,
      LogDefectKind.crack,
      LogDefectKind.knot,
    ]) {
      for (final entry in _known.entries) {
        if (entry.value == kind && key.contains(entry.key)) return kind;
      }
    }

    return null;
  }
}

/// Where a screen gets its detector from.
///
/// A single mutable seam rather than a constructor parameter threaded
/// through four widgets: when the model lands this is the only line that
/// changes, and tests can swap in a fake without rebuilding the widget tree.
class DefectDetection {
  DefectDetection._();

  static DefectDetector instance = const NoAutomaticDefectDetector();

  static bool get isAutomaticAvailable => instance.isAvailable;

  static void reset() => instance = const NoAutomaticDefectDetector();
}

/// Helper for detectors that classify the whole image.
extension WholeImageRegion on img.Image {
  Rect get fullRegion =>
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

  Offset get centrePoint => Offset(width / 2, height / 2);
}
