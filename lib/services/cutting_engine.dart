import 'dart:math' as math;

import '../models/cutting_models.dart';

/// Searches board orientation (0deg / 90deg) and grid offset to find the
/// arrangement that packs the most boards into the log's circular
/// cross-section. Real sawmills only ever cut boards parallel or
/// perpendicular to the log, so arbitrary-angle rotation is not attempted.
class CuttingEngine {
  static const int _offsetSteps = 8;

  static CuttingResult generate(CuttingInput input) {
    final double radius = input.logDiameter / 2;
    final double logArea = math.pi * radius * radius;

    _Arrangement? best;

    for (final swapped in [false, true]) {
      final double w = swapped ? input.boardHeight : input.boardWidth;
      final double h = swapped ? input.boardWidth : input.boardHeight;

      final arrangement = _bestArrangementFor(
        logDiameter: input.logDiameter,
        radius: radius,
        boardWidth: w,
        boardHeight: h,
        bladeThickness: input.bladeThickness,
        rotation: swapped ? 90.0 : 0.0,
      );

      if (arrangement == null) continue;

      // A single board's area (w*h) is unchanged by swapping width/height,
      // so whichever orientation fits more boards simply wins.
      if (best == null || arrangement.boards.length > best.boards.length) {
        best = arrangement;
      }
    }

    if (best == null) {
      return CuttingResult(
        boards: const [],
        boardCount: 0,
        utilization: 0,
        waste: 100,
        profit: 0,
        logArea: logArea,
        boardArea: 0,
        wasteArea: logArea,
        kerfLoss: 0,
        angle: 0,
        offsetX: 0,
        offsetY: 0,
      );
    }

    final double boardArea = best.boards.length * best.width * best.height;

    final double kerfPerCell = (best.width + input.bladeThickness) *
            (best.height + input.bladeThickness) -
        (best.width * best.height);

    final double kerfLoss = best.boards.length * kerfPerCell;

    final double utilization = (boardArea / logArea) * 100;
    final double waste = 100 - utilization;

    final double profit = best.boards.length * input.boardPrice;

    return CuttingResult(
      boards: best.boards,
      boardCount: best.boards.length,
      utilization: utilization,
      waste: waste,
      profit: profit,
      logArea: logArea,
      boardArea: boardArea,
      wasteArea: math.max(0, logArea - boardArea),
      kerfLoss: kerfLoss,
      angle: best.rotation,
      offsetX: best.offsetX,
      offsetY: best.offsetY,
    );
  }

  static _Arrangement? _bestArrangementFor({
    required double logDiameter,
    required double radius,
    required double boardWidth,
    required double boardHeight,
    required double bladeThickness,
    required double rotation,
  }) {
    final double spacingX = boardWidth + bladeThickness;
    final double spacingY = boardHeight + bladeThickness;

    final int cols = (logDiameter / spacingX).floor();
    final int rows = (logDiameter / spacingY).floor();

    if (cols <= 0 || rows <= 0) return null;

    final double totalGridWidth =
        cols * boardWidth + (cols - 1) * bladeThickness;

    final double totalGridHeight =
        rows * boardHeight + (rows - 1) * bladeThickness;

    final double slackX = math.max(0, logDiameter - totalGridWidth);
    final double slackY = math.max(0, logDiameter - totalGridHeight);

    _Arrangement? best;

    for (int sx = 0; sx <= _offsetSteps; sx++) {
      final double startX = slackX * sx / _offsetSteps;

      for (int sy = 0; sy <= _offsetSteps; sy++) {
        final double startY = slackY * sy / _offsetSteps;

        final boards = <BoardPiece>[];

        for (int r = 0; r < rows; r++) {
          for (int c = 0; c < cols; c++) {
            final double x = startX + c * spacingX;
            final double y = startY + r * spacingY;

            if (_boardFitsInsideCircle(
              x,
              y,
              boardWidth,
              boardHeight,
              radius,
            )) {
              boards.add(
                BoardPiece(
                  x: x,
                  y: y,
                  width: boardWidth,
                  height: boardHeight,
                  rotation: rotation,
                  index: boards.length + 1,
                ),
              );
            }
          }
        }

        if (best == null || boards.length > best.boards.length) {
          best = _Arrangement(
            boards: boards,
            width: boardWidth,
            height: boardHeight,
            rotation: rotation,
            offsetX: startX,
            offsetY: startY,
          );
        }
      }
    }

    return best;
  }

  static bool _boardFitsInsideCircle(
    double x,
    double y,
    double width,
    double height,
    double radius,
  ) {
    final List<math.Point<double>> corners = [
      math.Point(x, y),
      math.Point(x + width, y),
      math.Point(x, y + height),
      math.Point(x + width, y + height),
    ];

    for (final corner in corners) {
      final dx = corner.x - radius;
      final dy = corner.y - radius;

      final distance = math.sqrt(dx * dx + dy * dy);

      if (distance > radius) {
        return false;
      }
    }

    return true;
  }
}

class _Arrangement {
  final List<BoardPiece> boards;
  final double width;
  final double height;
  final double rotation;
  final double offsetX;
  final double offsetY;

  const _Arrangement({
    required this.boards,
    required this.width,
    required this.height,
    required this.rotation,
    required this.offsetX,
    required this.offsetY,
  });
}
