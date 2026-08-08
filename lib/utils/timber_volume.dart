import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'calculator.dart';

/// Which formula to use when turning a log's girth+length into a volume.
enum VolumeMethod {
  /// Straightforward cylinder volume (pi * r^2 * length), shown as a
  /// decimal cubic-feet number.
  standard,

  /// Traditional quarter-girth ("Hoppus") timber measure as printed in the
  /// Sri Lankan timber ready-reckoner, shown split into adi + angal.
  ///
  /// See [TimberVolumeCalculator.nulForGirth] for the derivation and for the
  /// verification against the printed book.
  referenceTable,
}

/// A volume, carried both as a decimal and at the ready-reckoner's grain.
///
/// The book does not express the remainder in cubic inches. It uses a
/// duodecimal ladder of *fractions of a cubic foot*:
///
///   1 adi (අඩි)   = 1 cubic foot
///   1 angal (අඟල්) = 1/12 cubic foot   -- NOT a cubic inch (1/1728)
///   1 nul (නුල්)   = 1/144 cubic foot
///
/// Conflating angal with cubic inches is a factor-of-144 error, so the two
/// representations are kept as separate fields rather than one being derived
/// loosely from the other.
///
/// This app works to angal and drops nul, truncating down exactly as the book
/// does. Because truncation only ever discards the third column, [adi] and
/// [angal] still match the book's printed first two columns exactly.
class VolumeResult {
  /// Canonical value used for storage, stack totals, and reports.
  final double cubicFeetDecimal;

  final int wholeCubicFeet;
  final int remainderCubicInches;

  /// The whole volume counted in nul (1/144 cubic foot). Under
  /// [VolumeMethod.referenceTable] this is always a whole number of angal,
  /// because nul is truncated away before it reaches here.
  final int totalNul;

  const VolumeResult({
    required this.cubicFeetDecimal,
    required this.wholeCubicFeet,
    required this.remainderCubicInches,
    this.totalNul = 0,
  });

  /// Rebuilds the full breakdown from a decimal volume, so a value loaded
  /// back from the database presents identically to one just calculated.
  factory VolumeResult.fromCubicFeet(double cubicFeet) {
    final double safe =
        (cubicFeet.isNaN || cubicFeet.isInfinite || cubicFeet < 0)
            ? 0.0
            : cubicFeet;
    final int whole = safe.floor();

    return VolumeResult(
      cubicFeetDecimal: safe,
      wholeCubicFeet: whole,
      remainderCubicInches: ((safe - whole) * 1728).round(),
      totalNul: (safe * TimberVolumeCalculator.nulPerCubicFoot +
              TimberVolumeCalculator.epsilon)
          .floor(),
    );
  }

  /// Whole cubic feet, as printed in the book's "සන අඩි" column.
  int get adi => totalNul ~/ TimberVolumeCalculator.nulPerCubicFoot;

  /// Twelfths of a cubic foot, as printed in the book's "අඟල්" column.
  int get angal =>
      (totalNul % TimberVolumeCalculator.nulPerCubicFoot) ~/
      TimberVolumeCalculator.nulPerAngal;

  String get display => "$wholeCubicFeet ft³ $remainderCubicInches in³";

  /// The reading as the trade states it: adi and angal, no nul.
  String get bookDisplay => "$adi adi $angal angal";
}

/// A running total over a stack, added the way the trade adds it.
///
/// Each log's adi and angal are counted in their own column and the carry is
/// only taken at the very end: every angal is summed, then divided by 12,
/// and the whole part is carried into the adi column.
///
/// This is deliberately integer arithmetic. Summing each log's decimal cubic
/// feet instead would accumulate binary rounding error across a long stack
/// and could land the printed total a hair either side of a boundary, which
/// on an invoice reads as the app being unable to add up.
@immutable
class StackVolumeTotal {
  final int adi;
  final int angal;

  /// How many logs went into this total, so a screen can show both.
  final int logCount;

  const StackVolumeTotal({
    this.adi = 0,
    this.angal = 0,
    this.logCount = 0,
  });

  factory StackVolumeTotal.of(Iterable<VolumeResult> logs) {
    int adiColumn = 0;
    int angalColumn = 0;
    int count = 0;

    for (final log in logs) {
      adiColumn += log.adi;
      angalColumn += log.angal;
      count++;
    }

    return StackVolumeTotal(
      adi: adiColumn + angalColumn ~/ TimberVolumeCalculator.nulPerAngal,
      angal: angalColumn % TimberVolumeCalculator.nulPerAngal,
      logCount: count,
    );
  }

  /// Adds one more log without rebuilding the whole stack -- the running
  /// total a live entry form needs as each row is filled in.
  StackVolumeTotal plus(VolumeResult log) {
    final carried = angal + log.angal;

    return StackVolumeTotal(
      adi: adi + log.adi + carried ~/ TimberVolumeCalculator.nulPerAngal,
      angal: carried % TimberVolumeCalculator.nulPerAngal,
      logCount: logCount + 1,
    );
  }

  /// The total as a decimal, for cost arithmetic and for the `stacks` table.
  double get cubicFeetDecimal =>
      adi + angal / TimberVolumeCalculator.nulPerAngal;

  String get display => "$adi adi $angal angal";

  @override
  bool operator ==(Object other) =>
      other is StackVolumeTotal &&
      other.adi == adi &&
      other.angal == angal &&
      other.logCount == logCount;

  @override
  int get hashCode => Object.hash(adi, angal, logCount);
}

class TimberVolumeCalculator {
  /// The book's smallest unit: 144 nul to the cubic foot.
  static const int nulPerCubicFoot = 144;

  /// 12 nul to the angal, 12 angal to the adi -- a duodecimal ladder.
  static const int nulPerAngal = 12;

  /// Guards the floor() calls below. A girth entered by tape is a clean
  /// number, but one derived from a LiDAR diameter via pi is irrational, so a
  /// value that is mathematically an exact whole number of nul can land a
  /// hair under it in binary floating point and lose a whole nul.
  static const double epsilon = 1e-9;

  /// The trade reads a tape down to the *completed* inch and a length down to
  /// the *completed* foot before ever opening the ready-reckoner: a log that
  /// tapes 26.9 in is bought as 26 in, and one that runs 4.9 ft is bought as
  /// 4 ft. It is truncation, never rounding -- 4.1 ft and 4.9 ft are both 4.
  ///
  /// This is a measurement *policy*, applied here on the way into the book
  /// rather than inside [nulForGirth], which stays a pure transcription of
  /// the printed table so it can still be verified cell-for-cell against it.
  ///
  /// Applied only under [VolumeMethod.referenceTable]. The standard cylinder
  /// method is a geometric answer, not a trade one, and stays continuous.
  static double toCompletedUnit(double value) {
    if (value.isNaN || value.isInfinite || value <= 0) return 0;

    // Without the epsilon a girth of a mathematically exact 26 in that
    // arrived via pi as 25.999999999 would be bought as 25 -- a whole inch
    // given away to a floating-point artefact.
    return (value + epsilon).floorToDouble();
  }

  static VolumeResult calculate({
    required VolumeMethod method,
    required double girthInches,
    required double lengthFeet,
  }) {
    final double cubicFeet = method == VolumeMethod.referenceTable
        ? _referenceTable(
            girthInches: toCompletedUnit(girthInches),
            lengthFeet: toCompletedUnit(lengthFeet),
          )
        : Calculator.calculateVolume(
            diameter: diameterInchesFromGirth(girthInches),
            lengthFeet: lengthFeet,
          );

    return VolumeResult.fromCubicFeet(cubicFeet);
  }

  /// The user and the book both speak girth (වට, the tape measurement right
  /// around the log). The LiDAR scanner and the cutting optimiser both speak
  /// diameter. These two are the only sanctioned crossing points.
  ///
  /// Note this is a geometric conversion assuming a circular section -- a
  /// tape laid around a real, out-of-round log will read slightly longer.
  static double girthInchesFromDiameter(double diameterInches) =>
      diameterInches * math.pi;

  static double diameterInchesFromGirth(double girthInches) =>
      girthInches / math.pi;

  /// Reproduces one cell of the ready-reckoner exactly, to the nul.
  ///
  /// Derivation. The book is quarter-girth (Hoppus) measure: treat the log's
  /// cross-section as a square whose side is a quarter of the girth.
  ///
  ///   volume_ft3 = (G/4)^2 / 144 * L
  ///
  /// and since the book counts in nul (1/144 ft3), multiplying by 144 makes
  /// the 144 cancel and leaves the whole formula the book is built on:
  ///
  ///   nul = (G/4)^2 * L
  ///
  /// with G in inches and L in feet. That collapse is not a coincidence: one
  /// nul is exactly a one-square-inch cross-section one foot long, which is
  /// the natural unit of quarter-girth measure. The book then *truncates* to
  /// a whole nul -- it never rounds up.
  ///
  /// Verified against 210 transcribed cells spanning girths 8-47 in and
  /// lengths 1/4-40 ft: 208 reproduce exactly. The two that do not (girth 26
  /// and girth 30, both at L=30) are slips in the book itself -- each is
  /// exactly 3x the book's own already-truncated L=10 row, i.e. compiled by
  /// tripling a rounded entry instead of recomputing. Girth 38 at L=30 was
  /// computed properly and does match. Both slips are 1 nul (0.007 ft3) low.
  static int nulForGirth({
    required double girthInches,
    required double lengthFeet,
  }) {
    if (girthInches.isNaN || lengthFeet.isNaN) return 0;
    if (girthInches.isInfinite || lengthFeet.isInfinite) return 0;
    if (girthInches <= 0 || lengthFeet <= 0) return 0;

    final double quarterGirth = girthInches / 4;
    final double exactNul = quarterGirth * quarterGirth * lengthFeet;

    return (exactNul + epsilon).floor();
  }

  /// The book reading this app actually bills on: the exact nul count with
  /// the nul column truncated away, leaving whole angal.
  ///
  /// Truncating rather than rounding matches the book's own rule, and keeps
  /// [VolumeResult.adi] and [VolumeResult.angal] equal to the book's printed
  /// first two columns. It does mean up to 11 nul (0.076 ft3) per log is
  /// discarded, always in the buyer's favour -- a deliberate, accepted
  /// trade-off for dropping the third column.
  static int angalForGirth({
    required double girthInches,
    required double lengthFeet,
  }) {
    final int nul = nulForGirth(
      girthInches: girthInches,
      lengthFeet: lengthFeet,
    );

    return nul ~/ nulPerAngal;
  }

  static double _referenceTable({
    required double girthInches,
    required double lengthFeet,
  }) {
    final int angal = angalForGirth(
      girthInches: girthInches,
      lengthFeet: lengthFeet,
    );

    // Return the truncated value, not the raw one: the whole point of this
    // method is that the app and the book agree column for column.
    return angal * nulPerAngal / nulPerCubicFoot;
  }
}
