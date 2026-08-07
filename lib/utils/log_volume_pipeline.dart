import '../services/user_preferences_service.dart';
import 'timber_volume.dart';

/// The single path from a measured log to a billable volume.
///
/// Deliberately extracted as pure functions rather than living inside a
/// screen: this is the calculation money changes hands over, so it must be
/// unit-testable in isolation.

/// Applies the user's trade/bark allowance to a measured girth.
///
/// Returns 0 rather than a negative number when the deduction meets or
/// exceeds the measurement -- a negative girth would square back into a
/// positive, plausible-looking volume, which is exactly the kind of silent
/// wrong answer that must never reach an invoice.
double effectiveGirthInches({
  required double measuredInches,
  required double deductionInches,
}) {
  if (measuredInches.isNaN ||
      measuredInches.isInfinite ||
      measuredInches <= 0) {
    return 0;
  }

  final deduction = UserPreferencesService.sanitizeDeduction(deductionInches);

  final effective = measuredInches - deduction;
  return effective > 0 ? effective : 0;
}

/// Computes a log's volume using the user's configured method and
/// deduction. Length is used as-is; only the girth carries an allowance.
VolumeResult volumeForLog({
  required UserPreferences prefs,
  required double measuredGirthInches,
  required double lengthFeet,
}) {
  final girth = effectiveGirthInches(
    measuredInches: measuredGirthInches,
    deductionInches: prefs.girthDeductionInches,
  );

  final safeLength =
      (lengthFeet.isNaN || lengthFeet.isInfinite || lengthFeet <= 0)
          ? 0.0
          : lengthFeet;

  if (girth <= 0 || safeLength <= 0) {
    return const VolumeResult(
      cubicFeetDecimal: 0,
      wholeCubicFeet: 0,
      remainderCubicInches: 0,
    );
  }

  return TimberVolumeCalculator.calculate(
    method: prefs.volumeMethod,
    girthInches: girth,
    lengthFeet: safeLength,
  );
}

/// Conversions between the units the sensor speaks (metres) and the units
/// the app stores (inches for diameter, feet for length).
///
/// Table-driven tests cover these because a silent unit slip is the classic
/// killer bug in a measurement app -- the existing LiDAR screen already
/// returns millimetres where the rest of the app expects inches/feet.
class MeasurementUnits {
  static const double _inchesPerMetre = 39.3700787401575;
  static const double _feetPerMetre = 3.28083989501312;

  static double metresToInches(double metres) => metres * _inchesPerMetre;

  static double metresToFeet(double metres) => metres * _feetPerMetre;

  static double inchesToMetres(double inches) => inches / _inchesPerMetre;

  static double feetToMetres(double feet) => feet / _feetPerMetre;
}
