import 'dart:math' as math;

import 'calculator.dart';

/// Which formula to use when turning a log's diameter+length into a volume.
enum VolumeMethod {
  /// Straightforward cylinder volume (pi * r^2 * length), shown as a
  /// decimal cubic-feet number.
  standard,

  /// Traditional quarter-girth ("Hoppus") timber measure, shown split into
  /// whole cubic feet + a remainder in cubic inches. This is the formula
  /// behind old Ceylon/Lanka timber ready-reckoner books: treat the log's
  /// cross-section as a square whose side is one quarter of the girth
  /// (circumference), which is a deliberate sawmill-era approximation, not
  /// the true cylindrical volume.
  ///
  /// NOTE: this is a best-effort default based on the standard quarter-girth
  /// formula -- it has not yet been verified digit-for-digit against a
  /// specific reference book. Adjust `TimberVolumeCalculator._referenceTable`
  /// here if a confirmed source shows different rounding/values.
  referenceTable,
}

class VolumeResult {
  /// Canonical value used for storage, stack totals, and reports.
  final double cubicFeetDecimal;

  final int wholeCubicFeet;
  final int remainderCubicInches;

  const VolumeResult({
    required this.cubicFeetDecimal,
    required this.wholeCubicFeet,
    required this.remainderCubicInches,
  });

  String get display => "$wholeCubicFeet ft³ $remainderCubicInches in³";
}

class TimberVolumeCalculator {
  static VolumeResult calculate({
    required VolumeMethod method,
    required double diameterInches,
    required double lengthFeet,
  }) {
    final double cubicFeet = method == VolumeMethod.referenceTable
        ? _referenceTable(
            diameterInches: diameterInches,
            lengthFeet: lengthFeet,
          )
        : Calculator.calculateVolume(
            diameter: diameterInches,
            lengthFeet: lengthFeet,
          );

    final int wholeFeet = cubicFeet.floor();
    final int remainderInches = ((cubicFeet - wholeFeet) * 1728).round();

    return VolumeResult(
      cubicFeetDecimal: cubicFeet,
      wholeCubicFeet: wholeFeet,
      remainderCubicInches: remainderInches,
    );
  }

  static double _referenceTable({
    required double diameterInches,
    required double lengthFeet,
  }) {
    final double girthInches = diameterInches * math.pi;
    final double quarterGirth = girthInches / 4;

    return (quarterGirth * quarterGirth) * lengthFeet / 144;
  }
}
