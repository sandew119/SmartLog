class LogModel {
  final double diameter;
  final double lengthFeet;
  final double volume;

  LogModel({
    required this.diameter,
    required this.lengthFeet,
    required this.volume,
  });

  Map<String, dynamic> toMap() {
    return {
      "diameter": diameter,
      "lengthFeet": lengthFeet,
      "volume": volume,
    };
  }

  factory LogModel.fromMap(Map<String, dynamic> map) {
    return LogModel(
      diameter: (map["diameter"] ?? 0).toDouble(),
      lengthFeet: (map["lengthFeet"] ?? 0).toDouble(),
      volume: (map["volume"] ?? 0).toDouble(),
    );
  }
}