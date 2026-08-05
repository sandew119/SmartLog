import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/services/user_preferences_service.dart';
import 'package:smartlog2/utils/log_volume_pipeline.dart';
import 'package:smartlog2/utils/timber_volume.dart';

void main() {
  group('effectiveDiameterInches', () {
    test('subtracts the deduction from the measured diameter', () {
      expect(
        effectiveDiameterInches(measuredInches: 20, deductionInches: 2),
        20 - 2,
      );
    });

    test('returns the measurement unchanged when deduction is zero', () {
      expect(
        effectiveDiameterInches(measuredInches: 15.5, deductionInches: 0),
        15.5,
      );
    });

    test(
        'clamps to 0 rather than going negative when the deduction exceeds '
        'the measurement', () {
      // A negative diameter would square back into a positive, plausible
      // volume -- the exact silent-wrong-answer this clamp exists to stop.
      expect(
        effectiveDiameterInches(measuredInches: 3, deductionInches: 5),
        0,
      );
    });

    test('treats a deduction equal to the measurement as zero', () {
      expect(
        effectiveDiameterInches(measuredInches: 4, deductionInches: 4),
        0,
      );
    });

    test('rejects NaN / infinite / non-positive measurements', () {
      expect(
        effectiveDiameterInches(measuredInches: double.nan, deductionInches: 1),
        0,
      );
      expect(
        effectiveDiameterInches(
          measuredInches: double.infinity,
          deductionInches: 1,
        ),
        0,
      );
      expect(
        effectiveDiameterInches(measuredInches: -5, deductionInches: 0),
        0,
      );
    });

    test('treats a NaN or negative deduction as no deduction at all', () {
      expect(
        effectiveDiameterInches(
          measuredInches: 10,
          deductionInches: double.nan,
        ),
        10,
      );
      expect(
        effectiveDiameterInches(measuredInches: 10, deductionInches: -3),
        10,
      );
    });

    test('clamps an absurdly large deduction to the documented maximum', () {
      // 30in deduction is a typo, not an intent; it clamps to 12 so the
      // result is a visibly-wrong small number rather than a silent zero.
      expect(
        effectiveDiameterInches(measuredInches: 40, deductionInches: 30),
        40 - UserPreferencesService.maxDeductionInches,
      );
    });
  });

  group('volumeForLog', () {
    test('matches TimberVolumeCalculator when there is no deduction', () {
      const prefs = UserPreferences(volumeMethod: VolumeMethod.standard);

      final actual = volumeForLog(
        prefs: prefs,
        measuredDiameterInches: 18,
        lengthFeet: 10,
      );

      final expected = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        diameterInches: 18,
        lengthFeet: 10,
      );

      expect(actual.cubicFeetDecimal, expected.cubicFeetDecimal);
    });

    test('a deduction lowers the volume quadratically, not linearly', () {
      const noDeduction = UserPreferences(diameterDeductionInches: 0);
      const withDeduction = UserPreferences(diameterDeductionInches: 2);

      final full = volumeForLog(
        prefs: noDeduction,
        measuredDiameterInches: 20,
        lengthFeet: 10,
      ).cubicFeetDecimal;

      final reduced = volumeForLog(
        prefs: withDeduction,
        measuredDiameterInches: 20,
        lengthFeet: 10,
      ).cubicFeetDecimal;

      // 20in -> 18in is a 10% diameter cut, but volume scales with d^2, so
      // the volume must drop by ~19%, not ~10%. This is the property that
      // makes diameter accuracy matter so much.
      expect(reduced, lessThan(full));
      expect(reduced / full, closeTo((18 * 18) / (20 * 20), 1e-9));
    });

    test('honours the reference-table method when selected', () {
      const prefs = UserPreferences(volumeMethod: VolumeMethod.referenceTable);

      final actual = volumeForLog(
        prefs: prefs,
        measuredDiameterInches: 20,
        lengthFeet: 12,
      );

      final expected = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        diameterInches: 20,
        lengthFeet: 12,
      );

      expect(actual.cubicFeetDecimal, expected.cubicFeetDecimal);

      // And it must genuinely differ from the standard formula.
      final standard = volumeForLog(
        prefs: const UserPreferences(volumeMethod: VolumeMethod.standard),
        measuredDiameterInches: 20,
        lengthFeet: 12,
      );
      expect(actual.cubicFeetDecimal, isNot(standard.cubicFeetDecimal));
    });

    test('returns a zero result instead of throwing on unusable input', () {
      const prefs = UserPreferences();

      for (final bad in [
        [0.0, 10.0],
        [18.0, 0.0],
        [double.nan, 10.0],
        [18.0, double.nan],
        [-4.0, 10.0],
      ]) {
        final result = volumeForLog(
          prefs: prefs,
          measuredDiameterInches: bad[0],
          lengthFeet: bad[1],
        );

        expect(result.cubicFeetDecimal, 0, reason: "input $bad");
      }
    });

    test('a deduction that wipes out the diameter yields zero volume', () {
      const prefs = UserPreferences(diameterDeductionInches: 6);

      final result = volumeForLog(
        prefs: prefs,
        measuredDiameterInches: 5,
        lengthFeet: 10,
      );

      expect(result.cubicFeetDecimal, 0);
    });
  });

  group('MeasurementUnits', () {
    test('converts metres to inches and feet at known reference values', () {
      // 1 inch is exactly 25.4mm, 1 foot exactly 304.8mm -- these are
      // definitions, so they must hold to floating-point precision.
      expect(MeasurementUnits.metresToInches(0.0254), closeTo(1.0, 1e-9));
      expect(MeasurementUnits.metresToFeet(0.3048), closeTo(1.0, 1e-9));
      expect(MeasurementUnits.metresToInches(1), closeTo(39.3700787, 1e-6));
      expect(MeasurementUnits.metresToFeet(1), closeTo(3.2808399, 1e-6));
    });

    test('round-trips without drift', () {
      for (final metres in [0.001, 0.25, 1.0, 3.6576, 12.7]) {
        expect(
          MeasurementUnits.inchesToMetres(
            MeasurementUnits.metresToInches(metres),
          ),
          closeTo(metres, 1e-9),
          reason: "$metres m via inches",
        );
        expect(
          MeasurementUnits.feetToMetres(
            MeasurementUnits.metresToFeet(metres),
          ),
          closeTo(metres, 1e-9),
          reason: "$metres m via feet",
        );
      }
    });

    test('a realistic log converts to sane trade units', () {
      // 0.45m diameter, 3.6m long -> ~17.7in, ~11.8ft.
      expect(MeasurementUnits.metresToInches(0.45), closeTo(17.72, 0.01));
      expect(MeasurementUnits.metresToFeet(3.6), closeTo(11.81, 0.01));
    });
  });
}
