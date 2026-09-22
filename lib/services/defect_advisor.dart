import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../models/log_defect.dart';
import '../utils/unit_display.dart';

/// Where on the cut face a defect sits.
///
/// Position changes what a defect means more than almost anything else. A
/// crack through the heart splits every board sawn across it; the same crack
/// out by the bark leaves with the first slab and costs nothing.
enum DefectZone { heart, middle, outer, unknown }

extension DefectZoneInfo on DefectZone {
  String get label => switch (this) {
        DefectZone.heart => "Heart",
        DefectZone.middle => "Mid-radius",
        DefectZone.outer => "Near the bark",
        DefectZone.unknown => "—",
      };
}

/// One defect as the advisor and the grader see it: what it is, where it is,
/// how big it is, and whether a person or a clear detection stands behind it.
class AssessedDefect {
  final LogDefectKind kind;

  /// The name to show -- the model's own word, or the kind for a hand mark.
  final String label;

  /// In photo pixels.
  final Rect region;

  /// A clear detection, or one a person confirmed or marked themselves.
  final bool confirmed;

  /// Marked by hand rather than found by the scan.
  final bool manual;

  final DefectZone zone;

  /// Longest side of the defect over the face diameter (or, with no traced
  /// face, over the short side of the photo). A crack's *box* can be mostly
  /// sound wood, so length says more about it than area does.
  final double extent;

  const AssessedDefect({
    required this.kind,
    required this.label,
    required this.region,
    required this.confirmed,
    this.manual = false,
    this.zone = DefectZone.unknown,
    this.extent = 0,
  });

  bool get isCrackLike =>
      kind == LogDefectKind.crack || kind == LogDefectKind.shake;

  bool get isHoleLike =>
      kind == LogDefectKind.hollow || kind == LogDefectKind.rot;

  /// Places a defect on the face.
  ///
  /// [faceCentre] and [faceRadius] are in the same photo pixels as
  /// [region]. Without them the zone is unknown and the extent is measured
  /// against the photo instead -- the capture screen tells people to fill
  /// the frame with the log, so it is a fair stand-in.
  factory AssessedDefect.locate({
    required LogDefectKind kind,
    required String label,
    required Rect region,
    required bool confirmed,
    required Size imageSize,
    bool manual = false,
    Offset? faceCentre,
    double? faceRadius,
  }) {
    final hasFace = faceCentre != null && faceRadius != null && faceRadius > 0;

    final reference = hasFace
        ? faceRadius * 2
        : math.max(1.0, math.min(imageSize.width, imageSize.height));

    DefectZone zone = DefectZone.unknown;

    if (hasFace) {
      if (region.inflate(faceRadius * 0.05).contains(faceCentre)) {
        zone = DefectZone.heart;
      } else {
        final distance = (region.center - faceCentre).distance / faceRadius;

        zone = distance < 0.35
            ? DefectZone.heart
            : (distance < 0.72 ? DefectZone.middle : DefectZone.outer);
      }
    }

    return AssessedDefect(
      kind: kind,
      label: label,
      region: region,
      confirmed: confirmed,
      manual: manual,
      zone: zone,
      extent: (region.longestSide / reference).clamp(0.0, 2.0),
    );
  }
}

/// SmartLog's own quality band for a log, from what is visible on its face.
///
/// Not a national grading rule and never presented as one -- those depend on
/// species, both ends, the surface along the length and the buyer. It is a
/// consistent first read of how clean this face is, so two logs can be
/// compared at a glance.
enum LogGrade { prime, select, standard, utility }

extension LogGradeInfo on LogGrade {
  String get letter => switch (this) {
        LogGrade.prime => "A",
        LogGrade.select => "B",
        LogGrade.standard => "C",
        LogGrade.utility => "D",
      };

  String get label => switch (this) {
        LogGrade.prime => "Prime",
        LogGrade.select => "Select",
        LogGrade.standard => "Standard",
        LogGrade.utility => "Utility",
      };

  String get meaning => switch (this) {
        LogGrade.prime =>
          "Clean face. A candidate for clear, appearance-grade boards.",
        LogGrade.select =>
          "Minor, sound knots only. Most boards should grade well.",
        LogGrade.standard =>
          "Visible defects that will downgrade some boards. Good for "
              "structural and general-purpose timber.",
        LogGrade.utility =>
          "Serious defects. Expect lower yield -- price by the sound wood, "
              "and saw for short or utility stock.",
      };
}

class GradeResult {
  final LogGrade grade;

  /// Why, in a line or two, so the letter never stands unexplained.
  final List<String> reasons;

  /// Findings still waiting for a person to confirm or dismiss them. The
  /// grade can move once they are resolved.
  final int pendingReview;

  const GradeResult({
    required this.grade,
    required this.reasons,
    this.pendingReview = 0,
  });
}

class LogQualityGrader {
  const LogQualityGrader._();

  /// Size thresholds, as a fraction of the face diameter.
  static const double largeKnot = 0.18;
  static const double longCrack = 0.5;
  static const double heartCrack = 0.3;
  static const double largeHole = 0.2;

  static GradeResult grade(List<AssessedDefect> defects) {
    final counted = [
      for (final d in defects)
        if (d.confirmed) d
    ];
    final pending = defects.length - counted.length;

    if (counted.isEmpty) {
      return GradeResult(
        grade: LogGrade.prime,
        reasons: [
          pending == 0
              ? "No defects found on this face."
              : "No confirmed defects. $pending faint "
                  "mark${pending == 1 ? '' : 's'} still to check.",
        ],
        pendingReview: pending,
      );
    }

    final reasons = <String>[];
    var grade = LogGrade.select;

    void atLeast(LogGrade g, String reason) {
      if (g.index > grade.index) grade = g;
      reasons.add(reason);
    }

    final knots = counted.where((d) => d.kind == LogDefectKind.knot).toList();
    final cracks = counted.where((d) => d.isCrackLike).toList();
    final rot = counted.where((d) => d.kind == LogDefectKind.rot).toList();
    final holes = counted.where((d) => d.kind == LogDefectKind.hollow).toList();

    if (rot.isNotEmpty) {
      atLeast(LogGrade.utility, "Rot present — decayed wood has no strength.");
    }

    for (final hole in holes) {
      if (hole.zone == DefectZone.heart || hole.extent >= largeHole) {
        atLeast(
          LogGrade.utility,
          hole.zone == DefectZone.heart
              ? "Hollow or hole at the heart."
              : "A large hole in the face.",
        );
        break;
      }
    }

    if (holes.isNotEmpty) {
      atLeast(
        LogGrade.standard,
        "${holes.length} hole${holes.length == 1 ? '' : 's'} in the face.",
      );
    }

    for (final crack in cracks) {
      final serious = crack.extent >= longCrack ||
          (crack.zone == DefectZone.heart && crack.extent >= heartCrack);

      if (serious) {
        atLeast(LogGrade.utility, "A long crack runs through the face.");
        break;
      }
    }

    if (cracks.isNotEmpty) {
      atLeast(
        LogGrade.standard,
        "${cracks.length} crack${cracks.length == 1 ? '' : 's'} visible.",
      );
    }

    if (knots.length >= 4) {
      atLeast(LogGrade.standard, "${knots.length} knots — a knotty face.");
    } else if (knots.any((k) => k.extent >= largeKnot)) {
      atLeast(LogGrade.standard, "At least one large knot.");
    } else if (knots.isNotEmpty) {
      reasons.add(
        "${knots.length} small knot${knots.length == 1 ? '' : 's'} only.",
      );
    }

    if (counted.length >= 7) {
      atLeast(LogGrade.utility, "${counted.length} defects on one face.");
    }

    // Keep the most serious reasons first and the list short.
    final unique = reasons.toSet().toList();

    return GradeResult(
      grade: grade,
      reasons: unique.take(3).toList(),
      pendingReview: pending,
    );
  }
}

/// How urgently a suggestion should be read.
enum AdvicePriority { critical, important, tip }

/// What a suggestion is about -- the screen picks an icon from this.
enum AdviceTopic {
  cutting,
  storage,
  inspection,
  pricing,
  grading,
  treatment,
  clean,
}

class DefectAdvice {
  final AdvicePriority priority;
  final AdviceTopic topic;
  final String title;
  final String body;

  const DefectAdvice({
    required this.priority,
    required this.topic,
    required this.title,
    required this.body,
  });
}

/// Turns findings into things a sawmill can actually do.
///
/// Rules, not a model: every suggestion here is standard sawmilling practice
/// keyed to what is on this face and where. It runs with or without a traced
/// face -- position-dependent advice simply waits until position is known.
class DefectAdvisor {
  const DefectAdvisor._();

  static List<DefectAdvice> advise({
    required List<AssessedDefect> defects,
    bool hasTracedFace = false,
    double lostCubicFeet = 0,
    double lostValue = 0,
    int maxItems = 7,
  }) {
    final advice = <DefectAdvice>[];

    final confirmed = [
      for (final d in defects)
        if (d.confirmed) d
    ];
    final pending = defects.length - confirmed.length;

    if (pending > 0) {
      advice.add(
        DefectAdvice(
          priority: AdvicePriority.important,
          topic: AdviceTopic.inspection,
          title: "Check $pending faint mark${pending == 1 ? '' : 's'} by eye",
          body: "The scan isn't certain about "
              "${pending == 1 ? 'one spot' : 'these spots'}. Look at the log, "
              "then confirm or dismiss each one so the count and the grade "
              "are right.",
        ),
      );
    }

    if (confirmed.isEmpty) {
      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.tip,
          topic: AdviceTopic.clean,
          title: "Clean face — keep it for your best orders",
          body: "Nothing found on this face. Prioritise this log for clear, "
              "appearance-grade boards and quote it accordingly.",
        ),
      );

      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.tip,
          topic: AdviceTopic.inspection,
          title: "Photograph the other end too",
          body: "Defects often show at only one end of a log. Check the other "
              "cut face before you settle on a price.",
        ),
      );

      return advice.take(maxItems).toList();
    }

    final knots = confirmed.where((d) => d.kind == LogDefectKind.knot).toList();
    final cracks = confirmed.where((d) => d.isCrackLike).toList();
    final holes =
        confirmed.where((d) => d.kind == LogDefectKind.hollow).toList();
    final rot = confirmed.where((d) => d.kind == LogDefectKind.rot).toList();

    // --- rot: the most urgent, because it spreads -------------------------
    if (rot.isNotEmpty) {
      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.critical,
          topic: AdviceTopic.cutting,
          title: "Cut out all rot, with a margin",
          body: "Decay reaches further than it looks. Leave at least 25 mm of "
              "extra wood around the soft area when you plan the cuts, and "
              "don't sell any piece that still contains it.",
        ),
      );

      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.important,
          topic: AdviceTopic.storage,
          title: "Keep this log away from sound stock",
          body: "Rot spreads in damp, still air. Store it apart, off the "
              "ground, and saw it soon.",
        ),
      );
    }

    // --- holes: insects and hollow hearts ---------------------------------
    if (holes.isNotEmpty) {
      final hollowHeart = holes.any((h) => h.zone == DefectZone.heart);

      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.critical,
          topic: AdviceTopic.inspection,
          title: "Check the holes for live borers",
          body: "Look for fresh, powdery sawdust (frass) around them. If it's "
              "there the insects are still active: saw this log quickly, kiln "
              "dry the timber rather than air-drying it, and keep it away "
              "from sound stock.",
        ),
      );

      if (hollowHeart) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.important,
            topic: AdviceTopic.cutting,
            title: "Hollow heart — saw around it",
            body: "Take the boards from the sound wood around the core and "
                "cut the centre out as one piece. Price the log on its sound "
                "volume, not its full girth.",
          ),
        );
      }
    }

    // --- cracks: orientation is everything --------------------------------
    if (cracks.isNotEmpty) {
      final throughHeart = cracks.any(
        (c) =>
            c.zone == DefectZone.heart ||
            c.extent >= LogQualityGrader.longCrack,
      );
      final onlyOuter = cracks.every((c) => c.zone == DefectZone.outer);

      if (throughHeart || (!hasTracedFace && cracks.isNotEmpty && !onlyOuter)) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.critical,
            topic: AdviceTopic.cutting,
            title: "Saw along the crack, not across it",
            body: "Turn the log so the first cuts run parallel to the crack. "
                "It then ends up inside one board or the centre piece "
                "instead of splitting every board it crosses.",
          ),
        );
      }

      if (onlyOuter && hasTracedFace) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.tip,
            topic: AdviceTopic.cutting,
            title: "Edge checks will come off with the slabs",
            body: "The cracks sit near the bark. Trim them out when edging — "
                "they shouldn't reach the boards.",
          ),
        );
      }

      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.important,
          topic: AdviceTopic.storage,
          title: "Seal the ends and saw soon",
          body: "Log ends dry fastest, and that is what makes cracks grow. "
              "Coat both ends with end-grain sealer, wax or thick paint today "
              "and move this log up the queue.",
        ),
      );
    }

    // --- knots: a grading question, not a disaster ------------------------
    if (knots.isNotEmpty) {
      final largeOrCentral = knots.any(
        (k) =>
            k.extent >= LogQualityGrader.largeKnot ||
            k.zone == DefectZone.heart,
      );

      if (knots.length >= 3) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.important,
            topic: AdviceTopic.grading,
            title: "Sell this one where knots are fine",
            body: "Framing, formwork, pallets and rustic furniture all accept "
                "knots. Keep clear-grade orders for cleaner logs.",
          ),
        );
      }

      if (largeOrCentral) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.important,
            topic: AdviceTopic.cutting,
            title: "Box the heart",
            body: "Keep the pith and the big knots together in one centre "
                "piece. The boards sawn from outside it stay cleaner and "
                "grade higher.",
          ),
        );
      } else if (hasTracedFace &&
          knots.every((k) => k.zone == DefectZone.outer)) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.tip,
            topic: AdviceTopic.grading,
            title: "Knots are in the side boards only",
            body: "They sit near the bark, so they'll fall in the outer "
                "boards. Grade those boards down, not the whole log.",
          ),
        );
      } else if (knots.length < 3) {
        advice.add(
          const DefectAdvice(
            priority: AdvicePriority.tip,
            topic: AdviceTopic.grading,
            title: "Small knots — a minor downgrade",
            body: "Sound, tight knots are accepted in most structural grades. "
                "Only boards that contain them lose grade.",
          ),
        );
      }
    }

    // --- money ---------------------------------------------------------------
    if (lostCubicFeet > 0.005) {
      final value = lostValue > 0
          ? " — about ${UnitDisplay.rupees(lostValue, decimals: 0)} at your rate"
          : "";

      advice.add(
        DefectAdvice(
          priority: AdvicePriority.important,
          topic: AdviceTopic.pricing,
          title: "Allow for the lost timber in the price",
          body: "On this log the defects cost about "
              "${lostCubicFeet.toStringAsFixed(2)} ft³ of boards$value. "
              "Factor that into what you pay for it.",
        ),
      );
    } else if (!hasTracedFace) {
      advice.add(
        const DefectAdvice(
          priority: AdvicePriority.tip,
          topic: AdviceTopic.pricing,
          title: "See what these defects cost",
          body: "Build a Log Report or plan the cut with the face traced, and "
              "the app will measure the boards and money each defect takes.",
        ),
      );
    }

    // Stable: within one priority, the order the rules were written in --
    // most specific first -- is kept.
    final order = {for (var i = 0; i < advice.length; i++) advice[i]: i};
    advice.sort((a, b) {
      final byPriority = a.priority.index.compareTo(b.priority.index);
      return byPriority != 0 ? byPriority : order[a]!.compareTo(order[b]!);
    });

    // Two rules can reach the same conclusion; say it once.
    final seen = <String>{};
    final unique = [
      for (final a in advice)
        if (seen.add(a.title)) a,
    ];

    return unique.take(maxItems).toList();
  }
}
