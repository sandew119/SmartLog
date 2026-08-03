import 'package:flutter/material.dart';

class BoardPosition {
  final double x;
  final double y;

  final double width;
  final double height;

  final double rotation;

  final int index;

  final bool accepted;

  final Color color;

  const BoardPosition({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
    required this.index,
    this.accepted = true,
    this.color = Colors.green,
  });

  Rect get rect => Rect.fromLTWH(
        x,
        y,
        width,
        height,
      );

  BoardPosition copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? index,
    bool? accepted,
    Color? color,
  }) {
    return BoardPosition(
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

  factory BoardPosition.fromMap(
    Map<String, dynamic> map,
  ) {
    return BoardPosition(
      x: (map["x"] as num).toDouble(),
      y: (map["y"] as num).toDouble(),
      width: (map["width"] as num).toDouble(),
      height: (map["height"] as num).toDouble(),
      rotation:
          (map["rotation"] as num).toDouble(),
      index: map["index"] as int,
      accepted:
          map["accepted"] as bool? ?? true,
    );
  }

  @override
  String toString() {
    return "BoardPosition(index: $index, x: $x, y: $y)";
  }
}