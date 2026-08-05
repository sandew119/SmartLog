import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/calculator.dart';
import 'package:smartlog2/utils/timber_volume.dart';

void main() {
  group('TimberVolumeCalculator', () {
    test('standard method matches Calculator.calculateVolume exactly', () {
      const diameter = 24.0;
      const length = 12.0;

      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        diameterInches: diameter,
        lengthFeet: length,
      );

      final expected = Calculator.calculateVolume(
        diameter: diameter,
        lengthFeet: length,
      );

      expect(result.cubicFeetDecimal, expected);
    });

    test(
        'reference table method uses the quarter-girth formula and gives a '
        'smaller volume than the standard cylinder formula', () {
      const diameter = 24.0;
      const length = 12.0;

      final standard = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        diameterInches: diameter,
        lengthFeet: length,
      );

      final table = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        diameterInches: diameter,
        lengthFeet: length,
      );

      // Quarter-girth measure is a deliberate historical underestimate of
      // the true cylindrical volume -- the two methods must never agree.
      expect(table.cubicFeetDecimal, lessThan(standard.cubicFeetDecimal));
      expect(table.cubicFeetDecimal, greaterThan(0));
    });

    test(
        'splits a decimal cubic-feet value into whole feet + remainder '
        'cubic inches consistently', () {
      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        diameterInches: 20,
        lengthFeet: 10,
      );

      final reconstructed =
          result.wholeCubicFeet + result.remainderCubicInches / 1728;

      expect(reconstructed, closeTo(result.cubicFeetDecimal, 0.001));
      expect(result.remainderCubicInches, greaterThanOrEqualTo(0));
      expect(result.remainderCubicInches, lessThan(1728));
    });

    test(
        'a girth of exactly 48 inches gives exactly L cubic feet with no '
        'remainder under the reference table method (quarter-girth = 1 '
        'foot exactly)', () {
      // girth = diameter * pi, so diameter = 48 / pi gives girth = 48in.
      final diameterForGirth48 = 48 / 3.141592653589793;

      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        diameterInches: diameterForGirth48,
        lengthFeet: 7,
      );

      expect(result.wholeCubicFeet, 7);
      expect(result.remainderCubicInches, closeTo(0, 1));
    });
  });
}
