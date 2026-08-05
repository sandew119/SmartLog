import 'log_model.dart';

class StackModel {
  final int id;
  final String name;
  final double totalVolume;
  final double totalCost;
  final DateTime createdAt;
  final List<LogModel> logs;

  StackModel({
    required this.id,
    required this.name,
    required this.totalVolume,
    this.totalCost = 0,
    required this.createdAt,
    this.logs = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      "id": id,
      "name": name,
      "totalVolume": totalVolume,
      "totalCost": totalCost,
      "createdAt": createdAt.toIso8601String(),
    };
  }

  factory StackModel.fromMap(
    Map<String, dynamic> map, {
    List<LogModel> logs = const [],
  }) {
    return StackModel(
      id: map["id"] as int,
      name: map["name"] as String? ?? "Stack",
      totalVolume: (map["totalVolume"] ?? 0).toDouble(),
      totalCost: (map["totalCost"] ?? 0).toDouble(),
      createdAt: map["createdAt"] != null
          ? DateTime.parse(map["createdAt"] as String)
          : DateTime.fromMillisecondsSinceEpoch(0),
      logs: logs,
    );
  }
}
