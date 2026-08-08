import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/calculator.dart';
import 'package:smartlog2/utils/timber_volume.dart';

void main() {
  group('TimberVolumeCalculator', () {
    test('standard method matches Calculator.calculateVolume exactly', () {
      const girth = 75.0;
      const length = 12.0;

      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        girthInches: girth,
        lengthFeet: length,
      );

      final expected = Calculator.calculateVolume(
        diameter: TimberVolumeCalculator.diameterInchesFromGirth(girth),
        lengthFeet: length,
      );

      expect(result.cubicFeetDecimal, expected);
    });

    test('girth and diameter convert round-trip without drift', () {
      const girth = 45.0;

      final diameter = TimberVolumeCalculator.diameterInchesFromGirth(girth);
      final back = TimberVolumeCalculator.girthInchesFromDiameter(diameter);

      expect(back, closeTo(girth, 1e-9));
      // A 45in tape reading is a log a shade over 14in across.
      expect(diameter, closeTo(14.3239, 0.0001));
    });

    test(
        'reference table method uses the quarter-girth formula and gives a '
        'smaller volume than the standard cylinder formula', () {
      const girth = 75.0;
      const length = 12.0;

      final standard = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        girthInches: girth,
        lengthFeet: length,
      );

      final table = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: girth,
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
        girthInches: 63,
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
      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 48,
        lengthFeet: 7,
      );

      expect(result.wholeCubicFeet, 7);
      expect(result.remainderCubicInches, closeTo(0, 1));
      expect(result.angal, 0);
    });
  });

  group('ready-reckoner reproduction', () {
    // Lengths down the left of every page, in feet.
    const lengths = <double>[
      0.25, 0.5, 0.75, //
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
      14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 30, 40,
    ];

    // Transcribed straight off the photographed pages, as (adi, angal, nul)
    // triples in the same order as `lengths`. Keyed by the page's girth.
    const book = <int, List<List<int>>>{
      8: [
        [0, 0, 1], [0, 0, 2], [0, 0, 3], [0, 0, 4], [0, 0, 8], [0, 1, 0],
        [0, 1, 4], [0, 1, 8], [0, 2, 0], [0, 2, 4], [0, 2, 8], [0, 3, 0],
        [0, 3, 4], [0, 3, 8], [0, 4, 0], [0, 4, 4], [0, 4, 8], [0, 5, 0],
        [0, 5, 4], [0, 5, 8], [0, 6, 0], [0, 6, 4], [0, 6, 8], [0, 7, 0],
        [0, 7, 4], [0, 7, 8], [0, 8, 0], [0, 8, 4], [0, 10, 0], [1, 1, 4],
      ],
      26: [
        [0, 0, 10], [0, 1, 9], [0, 2, 7], [0, 3, 6], [0, 7, 0], [0, 10, 6],
        [1, 2, 1], [1, 5, 7], [1, 9, 1], [2, 0, 7], [2, 4, 2], [2, 7, 8],
        [2, 11, 2], [3, 2, 8], [3, 6, 3], [3, 9, 9], [4, 1, 3], [4, 4, 9],
        [4, 8, 4], [4, 11, 10], [5, 3, 4], [5, 6, 10], [5, 10, 5], [6, 1, 11],
        [6, 5, 5], [6, 8, 11], [7, 0, 6], [7, 4, 0], [8, 9, 7], [11, 8, 10],
      ],
      30: [
        [0, 1, 2], [0, 2, 4], [0, 3, 6], [0, 4, 8], [0, 9, 4], [1, 2, 0],
        [1, 6, 9], [1, 11, 5], [2, 4, 1], [2, 8, 9], [3, 1, 6], [3, 6, 2],
        [3, 10, 10], [4, 3, 6], [4, 8, 3], [5, 0, 11], [5, 5, 7], [5, 10, 3],
        [6, 3, 0], [6, 7, 8], [7, 0, 4], [7, 5, 0], [7, 9, 9], [8, 2, 5],
        [8, 7, 1], [8, 11, 9], [9, 4, 6], [9, 9, 2], [11, 8, 7], [15, 7, 6],
      ],
      38: [
        [0, 1, 10], [0, 3, 9], [0, 5, 7], [0, 7, 6], [1, 3, 0], [1, 10, 6],
        [2, 6, 1], [3, 1, 7], [3, 9, 1], [4, 4, 7], [5, 0, 2], [5, 7, 8],
        [6, 3, 2], [6, 10, 8], [7, 6, 3], [8, 1, 9], [8, 9, 3], [9, 4, 9],
        [10, 0, 4], [10, 7, 10], [11, 3, 4], [11, 10, 10], [12, 6, 5],
        [13, 1, 11], [13, 9, 5], [14, 4, 11], [15, 0, 6], [15, 8, 0],
        [18, 9, 7], [25, 0, 10],
      ],
      44: [
        [0, 2, 6], [0, 5, 0], [0, 7, 6], [0, 10, 1], [1, 8, 2], [2, 6, 3],
        [3, 4, 4], [4, 2, 5], [5, 0, 6], [5, 10, 7], [6, 8, 8], [7, 6, 9],
        [8, 4, 10], [9, 2, 11], [10, 1, 0], [10, 11, 1], [11, 9, 2],
        [12, 7, 3], [13, 5, 4], [14, 3, 5], [15, 1, 6], [15, 11, 7],
        [16, 9, 8], [17, 7, 9], [18, 5, 10], [19, 3, 11], [20, 2, 0],
        [21, 0, 1], [25, 2, 6], [33, 7, 4],
      ],
      45: [
        [0, 2, 7], [0, 5, 3], [0, 7, 10], [0, 10, 6], [1, 9, 1], [2, 7, 7],
        [3, 6, 2], [4, 4, 8], [5, 3, 3], [6, 1, 9], [7, 0, 4], [7, 10, 11],
        [8, 9, 5], [9, 8, 0], [10, 6, 6], [11, 5, 1], [12, 3, 7], [13, 2, 2],
        [14, 0, 9], [14, 11, 3], [15, 9, 10], [16, 8, 4], [17, 6, 11],
        [18, 5, 5], [19, 4, 0], [20, 2, 6], [21, 1, 1], [21, 11, 8],
        [26, 4, 4], [35, 1, 10],
      ],
      47: [
        [0, 2, 10], [0, 5, 9], [0, 8, 7], [0, 11, 6], [1, 11, 0], [2, 10, 6],
        [3, 10, 0], [4, 9, 6], [5, 9, 0], [6, 8, 6], [7, 8, 0], [8, 7, 6],
        [9, 7, 0], [10, 6, 6], [11, 6, 0], [12, 5, 6], [13, 5, 0], [14, 4, 6],
        [15, 4, 1], [16, 3, 7], [17, 3, 1], [18, 2, 7], [19, 2, 1], [20, 1, 7],
        [21, 1, 1], [22, 0, 7], [23, 0, 1], [23, 11, 7], [28, 9, 1], [38, 4, 2],
      ],
    };

    test('nulForGirth reproduces every transcribed cell of the book', () {
      book.forEach((girth, rows) {
        for (var i = 0; i < lengths.length; i++) {
          final expected = rows[i][0] * 144 + rows[i][1] * 12 + rows[i][2];

          final actual = TimberVolumeCalculator.nulForGirth(
            girthInches: girth.toDouble(),
            lengthFeet: lengths[i],
          );

          expect(
            actual,
            expected,
            reason: 'girth ${girth}in x ${lengths[i]}ft',
          );
        }
      });
    });

    test('reports the book\'s adi and angal columns, with nul dropped', () {
      // Girth 45in x 40ft is the last row of the page-45 column: 35-1-10.
      // The app keeps 35 adi 1 angal and discards the 10 nul.
      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 45,
        lengthFeet: 40,
      );

      expect(result.adi, 35);
      expect(result.angal, 1);
      expect(result.bookDisplay, '35 adi 1 angal');
    });

    test(
        'adi and angal equal the book\'s first two columns at every whole '
        'foot', () {
      // Dropping nul only ever removes the third column, so the two the app
      // does show must still agree with the page for every cell the trade
      // actually buys on -- i.e. every completed foot.
      book.forEach((girth, rows) {
        for (var i = 0; i < lengths.length; i++) {
          if (lengths[i] != lengths[i].floorToDouble()) continue;

          final result = TimberVolumeCalculator.calculate(
            method: VolumeMethod.referenceTable,
            girthInches: girth.toDouble(),
            lengthFeet: lengths[i],
          );

          expect(
            [result.adi, result.angal],
            [rows[i][0], rows[i][1]],
            reason: 'girth ${girth}in x ${lengths[i]}ft',
          );
        }
      });
    });

    test('a part-foot log is bought at the completed foot below it', () {
      // The policy stated in trade terms: anything between 4 and 5 feet is
      // a 4-foot log. Checked against the book's own printed rows so this
      // is anchored to real data, not just to the formula.
      book.forEach((girth, rows) {
        final fourFootRow = rows[lengths.indexOf(4)];

        for (final partial in const <double>[4.0, 4.1, 4.5, 4.9, 4.99]) {
          final result = TimberVolumeCalculator.calculate(
            method: VolumeMethod.referenceTable,
            girthInches: girth.toDouble(),
            lengthFeet: partial,
          );

          expect(
            [result.adi, result.angal],
            [fourFootRow[0], fourFootRow[1]],
            reason: 'girth ${girth}in x ${partial}ft should bill as 4ft',
          );
        }
      });
    });

    test('a part-inch girth is bought at the completed inch below it', () {
      // 26.9in tapes as a 26in log, exactly as 26.0in does.
      final atWholeInch = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 26,
        lengthFeet: 10,
      );

      for (final partial in const <double>[26.0, 26.01, 26.5, 26.99]) {
        final result = TimberVolumeCalculator.calculate(
          method: VolumeMethod.referenceTable,
          girthInches: partial,
          lengthFeet: 10,
        );

        expect(
          [result.adi, result.angal],
          [atWholeInch.adi, atWholeInch.angal],
          reason: '${partial}in girth should bill as 26in',
        );
      }
    });

    test('truncation never rounds up across a boundary', () {
      // The failure that would cost a buyer money: 4.99ft billed as 5ft.
      final asFive = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 45,
        lengthFeet: 5,
      );
      final asAlmostFive = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 45,
        lengthFeet: 4.99,
      );

      expect(asAlmostFive.cubicFeetDecimal, lessThan(asFive.cubicFeetDecimal));
    });

    test('a girth arriving irrationally via pi still bills at its whole inch',
        () {
      // The LiDAR path derives girth as diameter * pi, so a log that is
      // mathematically exactly 36in around can land at 35.999999999. Without
      // the epsilon guard that log would silently be bought as 35in.
      final viaPi = TimberVolumeCalculator.girthInchesFromDiameter(
        TimberVolumeCalculator.diameterInchesFromGirth(36),
      );

      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: viaPi,
        lengthFeet: 12,
      );
      final exact = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 36,
        lengthFeet: 12,
      );

      expect(result.cubicFeetDecimal, exact.cubicFeetDecimal);
    });

    test('the standard cylinder method is left continuous', () {
      // Truncation is a trade rule for the book, not a geometric one. A
      // 4.9ft log must not collapse to 4ft under the standard method.
      final full = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        girthInches: 45.7,
        lengthFeet: 4.9,
      );
      final truncated = TimberVolumeCalculator.calculate(
        method: VolumeMethod.standard,
        girthInches: 45,
        lengthFeet: 4,
      );

      expect(full.cubicFeetDecimal, greaterThan(truncated.cubicFeetDecimal));
    });

    test('a log under one foot has no billable length under the book', () {
      // An honest consequence of whole-foot truncation, pinned so it can
      // never happen by accident: a 9-inch offcut bills as nothing.
      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 45,
        lengthFeet: 0.75,
      );

      expect(result.cubicFeetDecimal, 0);
    });

    test('truncates to a whole nul rather than rounding up', () {
      // 45in x 1ft is exactly 126.5625 nul. The book prints 10 angal 6 nul
      // (=126), not 127, so this must floor even past the halfway point.
      expect(
        TimberVolumeCalculator.nulForGirth(girthInches: 45, lengthFeet: 1),
        126,
      );
    });

    test('reference-table volume lands exactly on an angal boundary', () {
      // The billed decimal must be reconstructible from the displayed
      // reading, otherwise the invoice disagrees with what the user was
      // shown. 35 adi 1 angal = 421 angal.
      final result = TimberVolumeCalculator.calculate(
        method: VolumeMethod.referenceTable,
        girthInches: 45,
        lengthFeet: 40,
      );

      expect(result.totalNul % TimberVolumeCalculator.nulPerAngal, 0);
      expect(result.cubicFeetDecimal, 421 / 12);
    });

    test('rejects nonsense inputs instead of returning a plausible volume', () {
      expect(
        TimberVolumeCalculator.nulForGirth(girthInches: 0, lengthFeet: 10),
        0,
      );
      expect(
        TimberVolumeCalculator.nulForGirth(girthInches: -20, lengthFeet: 10),
        0,
      );
      expect(
        TimberVolumeCalculator.nulForGirth(
          girthInches: double.nan,
          lengthFeet: 10,
        ),
        0,
      );
    });
  });
}
