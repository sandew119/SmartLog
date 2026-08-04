class CuttingInput {
  final double bladeThickness;
  final double boardWidth;
  final double boardHeight;
  final double logDiameter;
  final double logLength;

  const CuttingInput({
    required this.bladeThickness,
    required this.boardWidth,
    required this.boardHeight,
    required this.logDiameter,
    required this.logLength,
  });
}

class BoardPiece {
  final double x;
  final double y;
  final double width;
  final double height;
  final int row;
  final int column;

  const BoardPiece({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.row,
    required this.column,
  });
}

class CuttingResult {
  final List<BoardPiece> boards;

  final int totalBoards;

  final double utilization;

  final double waste;

  final double logArea;

  final double usableArea;

  final double estimatedProfit;

  const CuttingResult({
    required this.boards,
    required this.totalBoards,
    required this.utilization,
    required this.waste,
    required this.logArea,
    required this.usableArea,
    required this.estimatedProfit,
  });
}