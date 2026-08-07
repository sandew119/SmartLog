import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/timber_volume.dart';

/// A log measured to exactly `adi` + `angal`, for building stacks by hand.
VolumeResult _log(int adi, int angal) =>
    VolumeResult.fromCubicFeet(adi + angal / 12);

void main() {
  group('StackVolumeTotal', () {
    test('an empty stack totals zero', () {
      const empty = StackVolumeTotal();

      expect(StackVolumeTotal.of(const []), empty);
      expect(empty.display, '0 adi 0 angal');
      expect(empty.cubicFeetDecimal, 0);
    });

    test('sums each column separately, then carries angal into adi', () {
      // 5 logs at 11 angal each = 55 angal = 4 adi 7 angal, on top of the
      // 10 adi already counted in the adi column.
      final total = StackVolumeTotal.of([
        _log(2, 11),
        _log(2, 11),
        _log(2, 11),
        _log(2, 11),
        _log(2, 11),
      ]);

      expect(total.adi, 14);
      expect(total.angal, 7);
      expect(total.logCount, 5);
      expect(total.display, '14 adi 7 angal');
    });

    test('carries only once, at the end, not per log', () {
      // Each log is under an adi, but together they are more than three.
      final total = StackVolumeTotal.of([
        _log(0, 11),
        _log(0, 11),
        _log(0, 11),
        _log(0, 11),
      ]);

      expect(total.adi, 3);
      expect(total.angal, 8);
    });

    test('plus() builds the same total as of(), one log at a time', () {
      final logs = [_log(3, 7), _log(0, 9), _log(12, 11), _log(1, 5)];

      var running = const StackVolumeTotal();
      for (final log in logs) {
        running = running.plus(log);
      }

      expect(running, StackVolumeTotal.of(logs));
      expect(running.adi, 18);
      expect(running.angal, 8);
    });

    test('stays exact over a long stack where decimals would drift', () {
      // 300 logs of 1/12 ft3 is exactly 25 ft3. Summing 0.08333... as a
      // double 300 times does not land on 25 -- summing integers does.
      final logs = List.generate(300, (_) => _log(0, 1));
      final total = StackVolumeTotal.of(logs);

      expect(total.adi, 25);
      expect(total.angal, 0);
      expect(total.cubicFeetDecimal, 25.0);
    });

    test('matches the real book values for a mixed stack', () {
      // Three logs off the pages we transcribed:
      //   girth 45 x 40ft -> 35 adi  1 angal
      //   girth 26 x 10ft ->  2 adi 11 angal
      //   girth 38 x  3ft ->  1 adi 10 angal
      // Angal column: 1 + 11 + 10 = 22 -> carries 1 adi, leaves 10.
      final logs = [
        [45.0, 40.0],
        [26.0, 10.0],
        [38.0, 3.0],
      ].map(
        (row) => TimberVolumeCalculator.calculate(
          method: VolumeMethod.referenceTable,
          girthInches: row[0],
          lengthFeet: row[1],
        ),
      );

      final total = StackVolumeTotal.of(logs);

      expect(total.adi, 39);
      expect(total.angal, 10);
    });
  });
}
