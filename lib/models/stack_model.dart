import 'log_model.dart';

class StackModel {
  final int id;
  final String name;
  final double totalVolume;
  final List<LogModel> logs;

  StackModel({
    required this.id,
    required this.name,
    required this.totalVolume,
    required this.logs,
  });

  Map<String, dynamic> toMap() {
    return {
      "id": id,
      "name": name,
      "totalVolume": totalVolume,
    };
  }
}