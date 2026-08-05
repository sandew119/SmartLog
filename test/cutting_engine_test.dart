import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/cutting_models.dart';
import 'package:smartlog2/services/cutting_engine.dart';

/// Reproduces the old V1 engine's behaviour: a single grid centered in the
/// log circle, no offset search, no orientation search. Used as a baseline
/// to prove the new optimizer never does worse.
int _naiveCenteredGridCount({
  required double logDiameter,
  required double boardWidth,
  required double boardHeight,
  required double bladeThickness,
}) {
  final double radius = logDiameter / 2;
  final double spacingX = boardWidth + bladeThickness;
  final double spacingY = boardHeight + bladeThickness;

  final int cols = (logDiameter / spacingX).floor();
  final int rows = (logDiameter / spacingY).floor();

  if (cols <= 0 || rows <= 0) return 0;

  final double totalGridWidth = cols * boardWidth + (cols - 1) * bladeThickness;
  final double totalGridHeight =
      rows * boardHeight + (rows - 1) * bladeThickness;

  final double startX = (logDiameter - totalGridWidth) / 2;
  final double startY = (logDiameter - totalGridHeight) / 2;

  int count = 0;

  for (int r = 0; r < rows; r++) {
    for (int c = 0; c < cols; c++) {
      final double x = startX + c * spacingX;
      final double y = startY + r * spacingY;

      final corners = [
        math.Point(x, y),
        math.Point(x + boardWidth, y),
        math.Point(x, y + boardHeight),
        math.Point(x + boardWidth, y + boardHeight),
      ];

      final fits = corners.every((corner) {
        final dx = corner.x - radius;
        final dy = corner.y - radius;
        return math.sqrt(dx * dx + dy * dy) <= radius;
      });

      if (fits) count++;
    }
  }

  return count;
}

void main() {
  group('CuttingEngine.generate', () {
    test(
        'never packs fewer boards than the naive centered-grid baseline, '
        'for either board orientation', () {
      const input = CuttingInput(
        logDiameter: 520,
        logLength: 3000,
        boardWidth: 100,
        boardHeight: 100,
        bladeThickness: 5,
        boardPrice: 250,
      );

      final result = CuttingEngine.generate(input);

      final baselineAsIs = _naiveCenteredGridCount(
        logDiameter: input.logDiameter,
        boardWidth: input.boardWidth,
        boardHeight: input.boardHeight,
        bladeThickness: input.bladeThickness,
      );

      final baselineSwapped = _naiveCenteredGridCount(
        logDiameter: input.logDiameter,
        boardWidth: input.boardHeight,
        boardHeight: input.boardWidth,
        bladeThickness: input.bladeThickness,
      );

      final bestBaseline = math.max(baselineAsIs, baselineSwapped);

      expect(result.boardCount, greaterThanOrEqualTo(bestBaseline));
      expect(result.boardCount, result.boards.length);
    });

    test('offset search finds more boards than a fixed centered grid', () {
      // For this log/board combination, a plain centered grid clips several
      // corner boards that a shifted grid can actually keep — a real,
      // verified case where the offset sweep beats the old V1 behaviour.
      const input = CuttingInput(
        logDiameter: 300,
        logLength: 2000,
        boardWidth: 40,
        boardHeight: 69,
        bladeThickness: 5,
        boardPrice: 100,
      );

      final result = CuttingEngine.generate(input);

      final centeredBaseline = _naiveCenteredGridCount(
        logDiameter: input.logDiameter,
        boardWidth: input.boardWidth,
        boardHeight: input.boardHeight,
        bladeThickness: input.bladeThickness,
      );

      expect(result.boardCount, greaterThan(centeredBaseline));
    });

    test('all placed boards actually fit inside the log circle', () {
      const input = CuttingInput(
        logDiameter: 480,
        logLength: 2500,
        boardWidth: 90,
        boardHeight: 40,
        bladeThickness: 3,
        boardPrice: 180,
      );

      final result = CuttingEngine.generate(input);
      final radius = input.logDiameter / 2;

      for (final board in result.boards) {
        final corners = [
          math.Point(board.x, board.y),
          math.Point(board.x + board.width, board.y),
          math.Point(board.x, board.y + board.height),
          math.Point(board.x + board.width, board.y + board.height),
        ];

        for (final corner in corners) {
          final dx = corner.x - radius;
          final dy = corner.y - radius;
          final distance = math.sqrt(dx * dx + dy * dy);
          expect(distance, lessThanOrEqualTo(radius + 1e-9));
        }
      }

      expect(result.profit, input.boardPrice * result.boardCount);
      expect(result.utilization, greaterThan(0));
      expect(result.utilization, lessThanOrEqualTo(100));
    });

    test('returns an empty, non-crashing result when no board can fit', () {
      const input = CuttingInput(
        logDiameter: 50,
        logLength: 1000,
        boardWidth: 200,
        boardHeight: 200,
        bladeThickness: 3,
        boardPrice: 100,
      );

      final result = CuttingEngine.generate(input);

      expect(result.boardCount, 0);
      expect(result.boards, isEmpty);
      expect(result.profit, 0);
      expect(result.waste, 100);
    });
  });
}
