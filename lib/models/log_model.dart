class LogModel {
  final int id;

  /// Null when this log is a standalone entry (not part of any stack).
  final int? stackId;

  final double diameter;
  final double lengthFeet;
  final double volume;
  final double cost;
  final DateTime createdAt;

  LogModel({
    required this.id,
    this.stackId,
    required this.diameter,
    required this.lengthFeet,
    required this.volume,
    this.cost = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      "id": id,
      "stackId": stackId,
      "diameter": diameter,
      "lengthFeet": lengthFeet,
      "volume": volume,
      "cost": cost,
      "createdAt": createdAt.toIso8601String(),
    };
  }

  factory LogModel.fromMap(Map<String, dynamic> map) {
    return LogModel(
      id: map["id"] as int,
      stackId: map["stackId"] as int?,
      diameter: (map["diameter"] ?? 0).toDouble(),
      lengthFeet: (map["lengthFeet"] ?? 0).toDouble(),
      volume: (map["volume"] ?? 0).toDouble(),
      cost: (map["cost"] ?? 0).toDouble(),
      createdAt: map["createdAt"] != null
          ? DateTime.parse(map["createdAt"] as String)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
