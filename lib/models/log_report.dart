import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../services/defect_advisor.dart';
import 'log_defect.dart';
import '../services/defect_impact.dart';
import '../utils/timber_volume.dart';
import 'sawing_models.dart';

/// Everything known about one log, assembled for its Log Passport.
///
/// A plain value: the builder screen gathers it, the report screen shows it
/// and the PDF prints it, and none of those three ever recompute anything --
/// so what is on screen and what is on paper cannot disagree.
class LogReportData {
  /// Printed on the report and in the file name, so a paper copy can be
  /// matched to the log it describes.
  final String reference;
  final DateTime createdAt;

  final String? species;
  final String? notes;

  /// Who produced it: the signed-in account's name or email, and their
  /// company from the profile. Both optional.
  final String? preparedBy;
  final String? company;

  // --- measurements ----------------------------------------------------------

  /// The tape reading, or the girth confirmed while tracing the face.
  final double girthInches;
  final double lengthFeet;

  /// Bark/trade allowance taken off the girth before the volume.
  final double deductionInches;

  final VolumeMethod volumeMethod;

  /// The volume the trade bills on, by [volumeMethod], after the deduction.
  final VolumeResult volume;

  /// The plain geometric cylinder, before any allowance -- for reference.
  final double cylinderCubicFeet;

  /// Agreed price per cubic foot of log, when one was entered.
  final double ratePerCubicFoot;

  /// Where the numbers came from, in words.
  final String measurementSource;

  /// Widest and narrowest across the traced face, in inches.
  final double? faceMajorInches;
  final double? faceMinorInches;

  // --- defects ---------------------------------------------------------------

  /// Every defect that counts: scan findings not dismissed, plus marks made
  /// by hand while tracing.
  final List<AssessedDefect> defects;

  /// Findings the person dismissed as not being defects.
  final int dismissedCount;

  /// Whether a defect scan ran at all. "No defects" and "not checked" must
  /// never print the same.
  final bool scanned;

  final GradeResult grade;
  final List<DefectAdvice> advice;

  /// The photo with every defect marked and numbered, as a PNG.
  final Uint8List? defectImage;

  // --- impact ----------------------------------------------------------------

  /// Per defect, for the confirmed defects that were measured.
  final List<DefectImpact> impacts;

  /// Board volume if the face were sound, and with the defects as they are.
  final double? soundYieldCubicFeet;
  final double? actualYieldCubicFeet;

  // --- cutting ---------------------------------------------------------------

  final SawingComparison? comparison;
  final SawingSetup? setup;

  /// The plan shown and recommended.
  final SawPlan? plan;

  /// True when [plan] routes boards around the confirmed defects.
  final bool planAvoidsDefects;

  final Uint8List? patternImage;

  const LogReportData({
    required this.reference,
    required this.createdAt,
    required this.girthInches,
    required this.lengthFeet,
    required this.volumeMethod,
    required this.volume,
    required this.cylinderCubicFeet,
    required this.defects,
    required this.grade,
    required this.advice,
    required this.measurementSource,
    this.species,
    this.notes,
    this.preparedBy,
    this.company,
    this.deductionInches = 0,
    this.ratePerCubicFoot = 0,
    this.faceMajorInches,
    this.faceMinorInches,
    this.dismissedCount = 0,
    this.scanned = false,
    this.defectImage,
    this.impacts = const [],
    this.soundYieldCubicFeet,
    this.actualYieldCubicFeet,
    this.comparison,
    this.setup,
    this.plan,
    this.planAvoidsDefects = false,
    this.patternImage,
  });

  double get diameterInches =>
      TimberVolumeCalculator.diameterInchesFromGirth(girthInches);

  /// The log's price at the agreed rate, on the billed volume.
  double get logValue => volume.cubicFeetDecimal * ratePerCubicFoot;

  bool get hasFaceShape => faceMajorInches != null && faceMinorInches != null;

  /// Board volume the defects take, all of them together.
  double get lostCubicFeet {
    final sound = soundYieldCubicFeet;
    final actual = actualYieldCubicFeet;
    if (sound == null || actual == null) return 0;
    return math.max(0, sound - actual);
  }

  double get lostValue {
    final rate = setup?.pricePerCubicFoot ?? 0;
    return lostCubicFeet * rate;
  }

  bool get hasImpact =>
      soundYieldCubicFeet != null && actualYieldCubicFeet != null;

  /// Counts per defect name, most serious kind first.
  List<({String label, int count})> get defectBreakdown {
    final counts = <String, int>{};
    final severity = <String, double>{};

    for (final d in defects) {
      counts[d.label] = (counts[d.label] ?? 0) + 1;
      severity[d.label] = d.kind.severity;
    }

    return [
      for (final e in counts.entries) (label: e.key, count: e.value),
    ]..sort((a, b) => severity[b.label]!.compareTo(severity[a.label]!));
  }

  /// A reference like SL-260923-1432: date and time, short enough to write
  /// on the log end in chalk.
  static String newReference(DateTime at) =>
      "SL-${DateFormat("yyMMdd-HHmm").format(at)}";
}
