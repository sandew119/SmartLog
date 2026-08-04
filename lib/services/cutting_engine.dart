import 'dart:math' as math;

import '../models/cutting_models.dart';

class CuttingEngine {
  static CuttingResult generate(CuttingInput input) {
    final List<BoardPiece> boards = [];

    final double radius = input.logDiameter / 2;

    final double spacingX =
        input.boardWidth + input.bladeThickness;

    final double spacingY =
        input.boardHeight + input.bladeThickness;

    final int cols =
        (input.logDiameter / spacingX).floor();

    final int rows =
        (input.logDiameter / spacingY).floor();

    final double totalGridWidth =
        cols * input.boardWidth +
            (cols - 1) * input.bladeThickness;

    final double totalGridHeight =
        rows * input.boardHeight +
            (rows - 1) * input.bladeThickness;

    final double startX =
        (input.logDiameter - totalGridWidth) / 2;

    final double startY =
        (input.logDiameter - totalGridHeight) / 2;

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final double x =
            startX + c * spacingX;

        final double y =
            startY + r * spacingY;

        if (_boardFitsInsideCircle(
          x,
          y,
          input.boardWidth,
          input.boardHeight,
          radius,
        )) {
          boards.add(
            BoardPiece(
              x: x,
              y: y,
              width: input.boardWidth,
              height: input.boardHeight,
              row: r,
              column: c,
            ),
          );
        }
      }
    }

    final double logArea =
        math.pi * radius * radius;

    final double usableArea =
        boards.length *
            input.boardWidth *
            input.boardHeight;

    final double utilization =
        usableArea / logArea * 100;

    final double waste =
        100 - utilization;

    final double profit =
        usableArea *
            input.logLength *
            0.0000025;

    return CuttingResult(
      boards: boards,
      totalBoards: boards.length,
      utilization: utilization,
      waste: waste,
      logArea: logArea,
      usableArea: usableArea,
      estimatedProfit: profit,
    );
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

      final distance =
          math.sqrt(dx * dx + dy * dy);

      if (distance > radius) {
        return false;
      }
    }

    return true;
  }
}