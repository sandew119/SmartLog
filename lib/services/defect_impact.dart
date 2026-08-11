import 'dart:math' as math;

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../models/sawing_models.dart';
import 'sawing_engine.dart';

/// How bad a defect is, in the words a buyer would use.
enum DefectSeverity { low, medium, high }

extension DefectSeverityInfo on DefectSeverity {
  String get label => switch (this) {
        DefectSeverity.low => "Low",
        DefectSeverity.medium => "Medium",
        DefectSeverity.high => "High",
      };

  /// Stored in the database as text, so the name has to be stable.
  String get stored => name;
}

/// What one defect costs this particular log.
class DefectImpact {
  final LogDefect defect;

  final DefectSeverity severity;

  /// Share of the cut face this defect covers, 0..1.
  final double faceFraction;

  /// Board volume this log yields with the defect taken into account.
  final double yieldWithDefectCubicFeet;

  /// What it would yield if the defect were not there.
  final double yieldIfSoundCubicFeet;

  /// Money, when a rate was supplied.
  final double lostValue;

  /// True when no board can cross it -- rot and hollows are wood that is
  /// simply absent. A knot still yields a sellable, lower-grade board.
  final bool blocksBoards;

  const DefectImpact({
    required this.defect,
    required this.severity,
    required this.faceFraction,
    required this.yieldWithDefectCubicFeet,
    required this.yieldIfSoundCubicFeet,
    required this.blocksBoards,
    this.lostValue = 0,
  });

  /// Cubic feet of boards this defect costs.
  double get lostCubicFeet {
    final lost = yieldIfSoundCubicFeet - yieldWithDefectCubicFeet;
    return lost <= 0 ? 0 : lost;
  }

  double get lostPercent => yieldIfSoundCubicFeet <= 0
      ? 0
      : (lostCubicFeet / yieldIfSoundCubicFeet) * 100;

  /// One sentence a sawmill owner can act on.
  ///
  /// Deliberately about *this* log rather than about the defect in general.
  /// "Rot is serious" is a fact anyone already knows; "this patch costs you
  /// 0.4 cubic feet of boards" is a reason to price differently.
  String get explanation {
    final buffer = StringBuffer();

    buffer.write(
      blocksBoards
          ? "No board can cross this — it is wood that isn't there. "
          : "A board containing this is still sellable, but at a lower "
              "grade. ",
    );

    if (lostCubicFeet > 0.001) {
      buffer.write(
        "On this log it costs about ${lostCubicFeet.toStringAsFixed(2)} ft³ "
        "of boards (${lostPercent.toStringAsFixed(0)}% of the yield)",
      );

      if (lostValue > 0) {
        buffer.write(", roughly Rs. ${lostValue.toStringAsFixed(0)}");
      }

      buffer.write(".");
    } else {
      buffer.write(
        "On this log it falls where no board was going to come from "
        "anyway, so it costs nothing.",
      );
    }

    return buffer.toString();
  }
}

/// Works out what defects actually cost, rather than only naming them.
///
/// This is the part a classifier cannot do. A model says "rot, 0.87". What a
/// sawmill owner needs to know is whether that patch is in the middle of the
/// log, where every board would have crossed it, or out at the edge where
/// only slab waste was coming from anyway. The same defect, the same
/// confidence, and two completely different prices.
///
/// The answer is obtained by asking the sawing engine twice: once with the
/// defect and once without. The difference is the cost.
class DefectImpactAnalyser {
  const DefectImpactAnalyser();

  /// Severity from what the defect is and how much of the face it covers.
  ///
  /// Both matter. A pinhole of rot is not a high-severity log, and a knot
  /// covering a third of the face is not a low-severity one, so neither the
  /// kind nor the size can decide this alone.
  static DefectSeverity severityOf(LogDefect defect, double faceFraction) {
    final kindWeight = defect.kind.severity;

    // Area counts for less than kind: rot is rot at any size, while a large
    // knot is still only a knot.
    final score = kindWeight * 0.7 + math.min(faceFraction * 4, 1.0) * 0.3;

    if (score >= 0.75) return DefectSeverity.high;
    if (score >= 0.45) return DefectSeverity.medium;
    return DefectSeverity.low;
  }

  /// The cost of each defect, one at a time.
  ///
  /// Each is measured against the plan for the log with *all* the others
  /// still present, so two overlapping patches do not each claim the whole
  /// loss and add up to more than the log is worth.
  List<DefectImpact> analyse({
    required LogFaceOutline outline,
    required List<LogDefect> defects,
    required SawingSetup setup,
  }) {
    if (defects.isEmpty) return const [];

    final faceArea = outline.area;

    final withAll = _yieldOf(outline, defects, setup);

    return [
      for (final defect in defects)
        _impactOf(
          outline: outline,
          defect: defect,
          others: [
            for (final other in defects)
              if (!identical(other, defect)) other,
          ],
          setup: setup,
          faceArea: faceArea,
          yieldWithAll: withAll,
        ),
    ];
  }

  DefectImpact _impactOf({
    required LogFaceOutline outline,
    required LogDefect defect,
    required List<LogDefect> others,
    required SawingSetup setup,
    required double faceArea,
    required double yieldWithAll,
  }) {
    final defectArea = math.pi * defect.radius * defect.radius;
    final fraction =
        faceArea <= 0 ? 0.0 : (defectArea / faceArea).clamp(0.0, 1.0);

    // The same log, planned as though this one defect were sound.
    final withoutThisOne = _yieldOf(outline, others, setup);

    final lost = math.max(0.0, withoutThisOne - yieldWithAll);

    return DefectImpact(
      defect: defect,
      severity: severityOf(defect, fraction),
      faceFraction: fraction,
      yieldWithDefectCubicFeet: yieldWithAll,
      yieldIfSoundCubicFeet: withoutThisOne,
      blocksBoards: defect.isDisqualifying,
      lostValue: lost * setup.pricePerCubicFoot,
    );
  }

  double _yieldOf(
    LogFaceOutline outline,
    List<LogDefect> defects,
    SawingSetup setup,
  ) {
    final comparison = SawingEngine.planBoth(
      setup.toRequest(outline, defects: defects, avoidDefects: true),
    );

    return comparison.best?.boardVolumeCubicFeet ?? 0;
  }

  /// The whole log in one line, for the top of the results screen.
  static String summarise(List<DefectImpact> impacts) {
    if (impacts.isEmpty) return "No defects found on this face.";

    final blocking = impacts.where((i) => i.blocksBoards).length;
    final totalLost =
        impacts.fold<double>(0, (sum, i) => sum + i.lostCubicFeet);

    final worst = impacts
        .map((i) => i.severity)
        .reduce((a, b) => a.index >= b.index ? a : b);

    final buffer = StringBuffer()
      ..write("${impacts.length} defect${impacts.length == 1 ? '' : 's'}")
      ..write(", worst is ${worst.label.toLowerCase()} severity");

    if (blocking > 0) {
      buffer.write(
        ". $blocking ${blocking == 1 ? 'is' : 'are'} wood that isn't there",
      );
    }

    if (totalLost > 0.001) {
      buffer.write(
        ". Together they cost about ${totalLost.toStringAsFixed(2)} ft³ of "
        "boards",
      );
    }

    return "$buffer.";
  }
}
