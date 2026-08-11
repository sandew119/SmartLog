import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/unit_display.dart';

void main() {
  group('lengths as a tape reads them', () {
    test('feet and inches', () {
      expect(UnitDisplay.feetAndInches(4.25), "4 ft 3 in");
      expect(UnitDisplay.feetAndInches(3.0), "3 ft 0 in");
    });

    test('under a foot drops the feet rather than printing zero', () {
      expect(UnitDisplay.feetAndInches(0.5), "6 in");
    });

    test('a rounded twelve carries instead of printing 12 in', () {
      // 3.999 ft is 11.99 in past three feet. Rounded naively that prints
      // "3 ft 12 in", which is not a length.
      expect(UnitDisplay.feetAndInches(3.999), "4 ft 0 in");
    });

    test('both systems, and a short piece reads in centimetres', () {
      // 0.66 ft was the whole complaint: a real measurement that looks like
      // a rounding error.
      final short = UnitDisplay.length(0.656);

      expect(short, contains("8 in"));
      expect(short, contains("cm"));
      expect(short, isNot(contains(" m")));
    });

    test('a full-size log reads in metres', () {
      final log = UnitDisplay.length(10);

      expect(log, contains("10 ft 0 in"));
      expect(log, contains("3.05 m"));
    });

    test('nonsense in, dash out', () {
      for (final bad in [double.nan, double.infinity, -1.0]) {
        expect(UnitDisplay.feetAndInches(bad), "—");
        expect(UnitDisplay.length(bad), "—");
        expect(UnitDisplay.across(bad), "—");
        expect(UnitDisplay.volume(bad), "—");
      }
    });
  });

  group('volumes at a grain that suits their size', () {
    test('a log is quoted in cubic feet and litres', () {
      final v = UnitDisplay.volume(12.5);

      expect(v, contains("12.500 ft³"));
      expect(v, contains("354.0 L"));
    });

    test('a cubic metre and up switches to m³', () {
      expect(UnitDisplay.volume(40), contains("m³"));
    });

    test('a small object is not reported as zero', () {
      // A 6 cm x 20 cm cylinder is 0.002 ft3. Printed to three decimals that
      // is "0.002 ft³", which tells the user nothing and looks like a bug --
      // which is exactly what it was taken for.
      final v = UnitDisplay.volume(0.002);

      expect(v, contains("in³"));
      expect(v, contains("ml"));
      expect(v, isNot(contains("0.002")));
    });

    test('cubic inches are not angal', () {
      // The two differ by 144x and both get called "inches" out loud.
      // Conflating them is a two-order-of-magnitude error on an invoice.
      expect(UnitDisplay.cubicInchesPerCubicFoot, 1728);

      final book = UnitDisplay.adiAngal(3, 7);

      expect(book, contains("adi"));
      expect(book, contains("angal"));
      expect(book, isNot(contains("in")));
    });
  });

  group('widths', () {
    test('inches and centimetres together', () {
      expect(UnitDisplay.across(26.5), "26.5 in  ·  67.3 cm");
    });

    test('a tolerance reads as a band', () {
      expect(UnitDisplay.tolerance(0.5), "±0.50 in (±1.3 cm)");
      expect(UnitDisplay.tolerance(0), "");
    });
  });
}
