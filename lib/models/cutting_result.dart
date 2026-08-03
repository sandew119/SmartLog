import 'board_position.dart';

class CuttingResult {
  /// Number of boards produced
  final int boardCount;

  /// Percentage of usable timber
  final double utilization;

  /// Percentage of waste
  final double waste;

  /// Estimated profit
  final double profit;

  /// Area of the log cross-section
  final double logArea;

  /// Total area occupied by boards
  final double boardArea;

  /// Total waste area
  final double wasteArea;

  /// Blade kerf loss
  final double kerfLoss;

  /// Rotation angle of the selected layout
  final double angle;

  /// Horizontal offset used by optimizer
  final double offsetX;

  /// Vertical offset used by optimizer
  final double offsetY;

  /// Generated board positions
  final List<BoardPosition> boards;

  const CuttingResult({
    required this.boardCount,
    required this.utilization,
    required this.waste,
    required this.profit,
    required this.logArea,
    required this.boardArea,
    required this.wasteArea,
    required this.kerfLoss,
    required this.angle,
    required this.offsetX,
    required this.offsetY,
    required this.boards,
  });

  CuttingResult copyWith({
    int? boardCount,
    double? utilization,
    double? waste,
    double? profit,
    double? logArea,
    double? boardArea,
    double? wasteArea,
    double? kerfLoss,
    double? angle,
    double? offsetX,
    double? offsetY,
    List<BoardPosition>? boards,
  }) {
    return CuttingResult(
      boardCount: boardCount ?? this.boardCount,
      utilization: utilization ?? this.utilization,
      waste: waste ?? this.waste,
      profit: profit ?? this.profit,
      logArea: logArea ?? this.logArea,
      boardArea: boardArea ?? this.boardArea,
      wasteArea: wasteArea ?? this.wasteArea,
      kerfLoss: kerfLoss ?? this.kerfLoss,
      angle: angle ?? this.angle,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      boards: boards ?? this.boards,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "boardCount": boardCount,
      "utilization": utilization,
      "waste": waste,
      "profit": profit,
      "logArea": logArea,
      "boardArea": boardArea,
      "wasteArea": wasteArea,
      "kerfLoss": kerfLoss,
      "angle": angle,
      "offsetX": offsetX,
      "offsetY": offsetY,
      "boards": boards.map((e) => e.toMap()).toList(),
    };
  }

  factory CuttingResult.fromMap(
    Map<String, dynamic> map,
  ) {
    return CuttingResult(
      boardCount: map["boardCount"] as int,
      utilization: (map["utilization"] as num).toDouble(),
      waste: (map["waste"] as num).toDouble(),
      profit: (map["profit"] as num).toDouble(),
      logArea: (map["logArea"] as num).toDouble(),
      boardArea: (map["boardArea"] as num).toDouble(),
      wasteArea: (map["wasteArea"] as num).toDouble(),
      kerfLoss: (map["kerfLoss"] as num).toDouble(),
      angle: (map["angle"] as num).toDouble(),
      offsetX: (map["offsetX"] as num).toDouble(),
      offsetY: (map["offsetY"] as num).toDouble(),
      boards: (map["boards"] as List)
          .map(
            (e) => BoardPosition.fromMap(
              e as Map<String, dynamic>,
            ),
          )
          .toList(),
    );
  }

  @override
  String toString() {
    return '''
Cutting Result

Boards          : $boardCount
Utilization     : ${utilization.toStringAsFixed(2)} %
Waste           : ${waste.toStringAsFixed(2)} %
Profit          : ${profit.toStringAsFixed(2)}
Log Area        : ${logArea.toStringAsFixed(2)}
Board Area      : ${boardArea.toStringAsFixed(2)}
Waste Area      : ${wasteArea.toStringAsFixed(2)}
Kerf Loss       : ${kerfLoss.toStringAsFixed(2)}
Rotation Angle  : ${angle.toStringAsFixed(2)}°
Offset X        : ${offsetX.toStringAsFixed(2)}
Offset Y        : ${offsetY.toStringAsFixed(2)}
''';
  }
}