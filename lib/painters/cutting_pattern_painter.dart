import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/cutting_models.dart';

class CuttingPatternPainter extends CustomPainter {
  final CuttingResult result;

  CuttingPatternPainter(this.result);

  @override
  void paint(Canvas canvas, Size size) {
    final double canvasSize =
        math.min(size.width, size.height);

    final double radius = canvasSize * 0.42;

    final Offset center = Offset(
      size.width / 2,
      size.height / 2,
    );

    final Rect logRect = Rect.fromCircle(
      center: center,
      radius: radius,
    );

    final barkPaint = Paint()
      ..color = const Color(0xFF5D4037);

    final woodPaint = Paint()
      ..color = const Color(0xFFD9B382);

    final boardPaint = Paint()
      ..color = Colors.green.shade600;

    final boardBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black;

    final logBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.black;

    // Bark
    canvas.drawCircle(
      center,
      radius + 8,
      barkPaint,
    );

    // Wood
    canvas.drawCircle(
      center,
      radius,
      woodPaint,
    );

    // Border
    canvas.drawCircle(
      center,
      radius,
      logBorder,
    );

    canvas.save();

    canvas.clipPath(
      Path()..addOval(logRect),
    );

    const designDiameter = 500.0;

    final scale =
        (radius * 2) / designDiameter;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    for (int i = 0;
        i < result.boards.length;
        i++) {

      final board = result.boards[i];

      final rect = Rect.fromLTWH(
        center.dx - radius + board.x * scale,
        center.dy - radius + board.y * scale,
        board.width * scale,
        board.height * scale,
      );

      canvas.drawRect(
        rect,
        boardPaint,
      );

      canvas.drawRect(
        rect,
        boardBorder,
      );

      textPainter.text = TextSpan(
        text: "${i + 1}",
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      );

      textPainter.layout();

      textPainter.paint(
        canvas,
        Offset(
          rect.center.dx -
              textPainter.width / 2,
          rect.center.dy -
              textPainter.height / 2,
        ),
      );
    }

    canvas.restore();

    final centerPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(center.dx - 12, center.dy),
      Offset(center.dx + 12, center.dy),
      centerPaint,
    );

    canvas.drawLine(
      Offset(center.dx, center.dy - 12),
      Offset(center.dx, center.dy + 12),
      centerPaint,
    );

    final utilPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text:
            "Yield : ${result.utilization.toStringAsFixed(1)} %",
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.black,
          fontSize: 18,
        ),
      ),
    );

    utilPainter.layout();

    utilPainter.paint(
      canvas,
      Offset(
        size.width / 2 -
            utilPainter.width / 2,
        15,
      ),
    );
  }

  @override
  bool shouldRepaint(
      covariant CuttingPatternPainter oldDelegate) {
    return oldDelegate.result != result;
  }
}