import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/log_defect.dart';
import '../services/defect_detector.dart';
import '../services/defect_impact.dart';
import '../utils/fitted_image_mapper.dart';

/// Draws what the model found on top of the photograph it found it in.
///
/// The point is inspectability. A sawmill owner will not act on "this log
/// has rot" from a box that shows its working to nobody — being able to see
/// *where* the model looked is what makes the answer worth anything, and it
/// also catches a model that is right for the wrong reason, such as keying
/// on the background rather than the timber.
class DefectOverlayPainter extends CustomPainter {
  final ui.Image photo;
  final Size imageSize;

  final List<DefectFinding> findings;

  /// Severity per finding, by index. Empty until the impact analysis has
  /// run, which needs a traced outline the defect screen may not have.
  final List<DefectSeverity> severities;

  /// Class activation map, 0..1 row-major. Null for an object detector,
  /// whose boxes already say where it looked.
  final List<double>? activation;
  final int activationWidth;
  final int activationHeight;

  final bool showHeatmap;

  DefectOverlayPainter({
    required this.photo,
    required this.imageSize,
    required this.findings,
    this.severities = const [],
    this.activation,
    this.activationWidth = 0,
    this.activationHeight = 0,
    this.showHeatmap = true,
  });

  static const _low = Color(0xFFFFC107);
  static const _medium = Color(0xFFFF7043);
  static const _high = Color(0xFFD32F2F);

  static Color colourFor(DefectSeverity severity) => switch (severity) {
        DefectSeverity.low => _low,
        DefectSeverity.medium => _medium,
        DefectSeverity.high => _high,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final mapper = FittedImageMapper(imageSize: imageSize, boxSize: size);
    final display = mapper.displayRect;

    canvas.drawImageRect(
      photo,
      Rect.fromLTWH(0, 0, imageSize.width, imageSize.height),
      display,
      Paint()..filterQuality = FilterQuality.medium,
    );

    if (showHeatmap) _drawHeatmap(canvas, display);

    for (var i = 0; i < findings.length; i++) {
      final finding = findings[i];
      if (finding.isHealthy) continue;

      final severity =
          i < severities.length ? severities[i] : DefectSeverity.medium;

      _drawFinding(canvas, mapper, finding, colourFor(severity));
    }
  }

  /// The activation map, painted as a warm wash where the model was looking.
  ///
  /// Drawn as translucent cells rather than a smooth gradient: a smoothed
  /// heatmap looks more precise than the 7x7 grid a ResNet actually produces,
  /// and implying precision the model does not have is its own kind of lie.
  void _drawHeatmap(Canvas canvas, Rect display) {
    final map = activation;
    if (map == null || activationWidth <= 0 || activationHeight <= 0) return;

    final cellWidth = display.width / activationWidth;
    final cellHeight = display.height / activationHeight;

    for (var y = 0; y < activationHeight; y++) {
      for (var x = 0; x < activationWidth; x++) {
        final value = map[y * activationWidth + x].clamp(0.0, 1.0);

        // Below this the cell says nothing, and painting it only dirties
        // the photograph.
        if (value < 0.35) continue;

        canvas.drawRect(
          Rect.fromLTWH(
            display.left + x * cellWidth,
            display.top + y * cellHeight,
            cellWidth,
            cellHeight,
          ),
          Paint()
            ..color = Color.lerp(
              const Color(0x00FF8F00),
              const Color(0xFFD32F2F),
              value,
            )!
                .withValues(alpha: (value - 0.3) * 0.55),
        );
      }
    }
  }

  void _drawFinding(
    Canvas canvas,
    FittedImageMapper mapper,
    DefectFinding finding,
    Color colour,
  ) {
    final topLeft = mapper.toScreen(finding.region.topLeft);
    final bottomRight = mapper.toScreen(finding.region.bottomRight);
    final rect = Rect.fromPoints(topLeft, bottomRight);

    // A whole-image classifier reports the entire frame. Boxing the whole
    // photograph tells the user nothing, so that case is left to the
    // heatmap.
    final coversEverything = rect.width >= mapper.displayRect.width * 0.95 &&
        rect.height >= mapper.displayRect.height * 0.95;

    if (coversEverything) return;

    final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(6));

    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = colour,
    );

    canvas.drawRRect(
      rounded,
      Paint()..color = colour.withValues(alpha: 0.12),
    );

    _drawLabel(
      canvas,
      rect,
      "${finding.kind.label}  ${(finding.confidence * 100).round()}%",
      colour,
    );
  }

  void _drawLabel(Canvas canvas, Rect rect, String text, Color colour) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    )..layout();

    // Above the box, unless that would fall off the top of the picture.
    final above = rect.top - painter.height - 8 > 0;

    final background = Rect.fromLTWH(
      rect.left,
      above ? rect.top - painter.height - 8 : rect.bottom + 2,
      painter.width + 12,
      painter.height + 6,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(background, const Radius.circular(4)),
      Paint()..color = colour,
    );

    painter.paint(
      canvas,
      Offset(background.left + 6, background.top + 3),
    );
  }

  @override
  bool shouldRepaint(covariant DefectOverlayPainter old) {
    return old.photo != photo ||
        old.findings != findings ||
        old.severities != severities ||
        old.showHeatmap != showHeatmap ||
        old.activation != activation;
  }
}
