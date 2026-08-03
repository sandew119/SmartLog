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
      logDiameter:
          logDiameter ?? this.logDiameter,
      logLength:
          logLength ?? this.logLength,
      boardWidth:
          boardWidth ?? this.boardWidth,
      boardHeight:
          boardHeight ?? this.boardHeight,
      bladeThickness:
          bladeThickness ??
              this.bladeThickness,
      boardPrice:
          boardPrice ?? this.boardPrice,
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

  factory CuttingInput.fromMap(
      Map<String, dynamic> map) {
    return CuttingInput(
      logDiameter:
          (map["logDiameter"] as num)
              .toDouble(),
      logLength:
          (map["logLength"] as num)
              .toDouble(),
      boardWidth:
          (map["boardWidth"] as num)
              .toDouble(),
      boardHeight:
          (map["boardHeight"] as num)
              .toDouble(),
      bladeThickness:
          (map["bladeThickness"] as num)
              .toDouble(),
      boardPrice:
          (map["boardPrice"] as num)
              .toDouble(),
    );
  }
}