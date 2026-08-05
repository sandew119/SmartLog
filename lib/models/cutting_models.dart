import 'package:flutter/material.dart';

class CuttingInput {
  final double logDiameter;

  final double logLength;

  final double boardWidth;

  final double boardHeight;

  final double bladeThickness;

  final double boardPrice;

  const CuttingInput({
    required this.logDiameter,
    required this.logLength,
    required this.boardWidth,
    required this.boardHeight,
    required this.bladeThickness,
    required this.boardPrice,
  });

  CuttingInput copyWith({
    double? logDiameter,
    double? logLength,
    double? boardWidth,
    double? boardHeight,
    double? bladeThickness,
    double? boardPrice,
  }) {
    return CuttingInput(
      logDiameter: logDiameter ?? this.logDiameter,
      logLength: logLength ?? this.logLength,
      boardWidth: boardWidth ?? this.boardWidth,
      boardHeight: boardHeight ?? this.boardHeight,
      bladeThickness: bladeThickness ?? this.bladeThickness,
      boardPrice: boardPrice ?? this.boardPrice,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "logDiameter": logDiameter,
      "logLength": logLength,
      "boardWidth": boardWidth,
      "boardHeight": boardHeight,
      "bladeThickness": bladeThickness,
      "boardPrice": boardPrice,
    };
  }

  factory CuttingInput.fromMap(Map<String, dynamic> map) {
    return CuttingInput(
      logDiameter: (map["logDiameter"] as num).toDouble(),
      logLength: (map["logLength"] as num).toDouble(),
      boardWidth: (map["boardWidth"] as num).toDouble(),
      boardHeight: (map["boardHeight"] as num).toDouble(),
      bladeThickness: (map["bladeThickness"] as num).toDouble(),
      boardPrice: (map["boardPrice"] as num).toDouble(),
    );
  }
}

/// A single board cut from the log cross-section.
class BoardPiece {
  final double x;
  final double y;

  final double width;
  final double height;

  /// 0 or 90 — degrees the board is rotated relative to [CuttingInput.boardWidth]/[CuttingInput.boardHeight].
  final double rotation;

  final int index;

  final bool accepted;

  final Color color;

  const BoardPiece({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
    required this.index,
    this.accepted = true,
    this.color = Colors.green,
  });

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  BoardPiece copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? index,
    bool? accepted,
    Color? color,
  }) {
    return BoardPiece(
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      index: index ?? this.index,
      accepted: accepted ?? this.accepted,
      color: color ?? this.color,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "x": x,
      "y": y,
      "width": width,
      "height": height,
      "rotation": rotation,
      "index": index,
      "accepted": accepted,
    };
  }

  factory BoardPiece.fromMap(Map<String, dynamic> map) {
    return BoardPiece(
      x: (map["x"] as num).toDouble(),
      y: (map["y"] as num).toDouble(),
      width: (map["width"] as num).toDouble(),
      height: (map["height"] as num).toDouble(),
      rotation: (map["rotation"] as num).toDouble(),
      index: map["index"] as int,
      accepted: map["accepted"] as bool? ?? true,
    );
  }
}

class CuttingResult {
  final List<BoardPiece> boards;

  /// Number of boards produced.
  final int boardCount;

  /// Percentage of usable timber.
  final double utilization;

  /// Percentage of waste.
  final double waste;

  /// Estimated profit (boardCount * boardPrice).
  final double profit;

  /// Area of the log cross-section.
  final double logArea;

  /// Total area occupied by boards.
  final double boardArea;

  /// Total waste area (log area minus board area minus kerf loss).
  final double wasteArea;

  /// Total area lost to blade kerf between boards.
  final double kerfLoss;

  /// Rotation angle (0 or 90) chosen by the optimizer.
  final double angle;

  /// Horizontal offset chosen by the optimizer.
  final double offsetX;

  /// Vertical offset chosen by the optimizer.
  final double offsetY;

  const CuttingResult({
    required this.boards,
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
  });

  CuttingResult copyWith({
    List<BoardPiece>? boards,
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
  }) {
    return CuttingResult(
      boards: boards ?? this.boards,
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

  factory CuttingResult.fromMap(Map<String, dynamic> map) {
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
          .map((e) => BoardPiece.fromMap(e as Map<String, dynamic>))
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
