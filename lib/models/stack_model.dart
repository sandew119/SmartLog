import 'log_model.dart';

class StackModel {
  final int id;
  final String name;
  final double totalVolume;
  final double totalCost;
  final DateTime createdAt;
  final List<LogModel> logs;

  /// Who the stack is for. Optional -- null when the user didn't say.
  ///
  /// Note there is no company field here on purpose. The *seller's* company
  /// lives on the user's profile and is read from there when a report is
  /// generated; asking for it again per stack would be busywork.
  final String? customerName;

  /// Free-text note the user attached to the stack. Optional.
  final String? remarks;

  StackModel({
    required this.id,
    required this.name,
    required this.totalVolume,
    this.totalCost = 0,
    required this.createdAt,
    this.logs = const [],
    this.customerName,
    this.remarks,
  });

  Map<String, dynamic> toMap() {
    return {
      "id": id,
      "name": name,
      "totalVolume": totalVolume,
      "totalCost": totalCost,
      "createdAt": createdAt.toIso8601String(),
      "customerName": customerName,
      "remarks": remarks,
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
      customerName: _text(map["customerName"]),
      remarks: _text(map["remarks"]),
    );
  }

  /// Rows written before these columns existed carry nulls, and a row that
  /// somehow stored an empty string should read the same as absent.
  static String? _text(Object? value) {
    final text = (value as String?)?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}
