import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/sawing_models.dart';
import '../utils/fitted_image_mapper.dart';

/// Draws a sawing plan over the photograph of the log it was planned for.
///
/// The painter this replaces drew an abstract circle with a hardcoded
/// 500-unit diameter, ignored the board rotation entirely, and had no idea
/// what the log actually looked like -- so the pattern on screen bore no
/// relation to the log in the user's hand. This one draws on the real
/// photograph, inside the boundary they traced, and marks the cant
/// separately because that is the first cut the sawyer physically makes.
class SawingPatternPainter extends CustomPainter {
  final SawPlan plan;

  /// Millimetres per photo pixel, so the plan (in mm) can be placed back on
  /// the image it came from.
  final double mmPerPixel;

  /// Where the traced face sits in the photo, in image pixels. The plan's
  /// own coordinates are normalised to its bounding box, so this is what
  /// puts it back in the right place.
  final Offset faceOriginPx;

  final Size imageSize;

  /// Null when there is no photo -- the manual path, where the pattern is
  /// drawn on a plain background instead.
  final ui.Image? photo;

  final bool showCutNumbers;

  SawingPatternPainter({
    required this.plan,
    required this.mmPerPixel,
    required this.faceOriginPx,
    required this.imageSize,
    this.photo,
    this.showCutNumbers = true,
  });

  static const _cantColour = Color(0xFF1565C0);
  static const _cantBoardColour = Color(0xFF42A5F5);
  static const _sideBoardColour = Color(0xFF66BB6A);
  static const _outlineColour = Color(0xFFFFC107);

  @override
  void paint(Canvas canvas, Size size) {
    if (mmPerPixel <= 0 || !mmPerPixel.isFinite) return;

    final mapper = FittedImageMapper(imageSize: imageSize, boxSize: size);
    final display = mapper.displayRect;

    if (photo != null) {
      canvas.drawImageRect(
        photo!,
        Rect.fromLTWH(0, 0, imageSize.width, imageSize.height),
        display,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      canvas.drawRect(display, Paint()..color = const Color(0xFF2A2A2A));
    }

    // Dim the photo so the pattern reads clearly against bark and sawdust
    // without hiding the log itself.
    canvas.drawRect(
        display, Paint()..color = Colors.black.withValues(alpha: 0.28));

    /// A point in plan millimetres, in widget coordinates.
    Offset toScreen(Offset mm) => mapper.toScreen(
          Offset(
            faceOriginPx.dx + mm.dx / mmPerPixel,
            faceOriginPx.dy + mm.dy / mmPerPixel,
          ),
        );

    _drawOutline(canvas, toScreen);
    _drawCant(canvas, toScreen);
    _drawBoards(canvas, toScreen, mapper);
    _drawLegend(canvas, size);
  }

  void _drawOutline(Canvas canvas, Offset Function(Offset) toScreen) {
    final points = plan.outline.points;
    if (points.length < 3) return;

    final path = Path()
      ..moveTo(toScreen(points.first).dx, toScreen(points.first).dy);

    for (final p in points.skip(1)) {
      final s = toScreen(p);
      path.lineTo(s.dx, s.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = _outlineColour,
    );
  }

  /// The rotation the whole pattern sits at. Boards are planned axis-aligned
  /// in a turned frame, so everything drawn from here is turned back.
  Offset _rotate(Offset mm) {
    final c = math.cos(plan.patternAngle);
    final s = math.sin(plan.patternAngle);
    final o = plan.rotationCentre;

    return Offset(
      o.dx + (mm.dx - o.dx) * c - (mm.dy - o.dy) * s,
      o.dy + (mm.dx - o.dx) * s + (mm.dy - o.dy) * c,
    );
  }

  Path _rectPath(Rect rect, Offset Function(Offset) toScreen) {
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ].map((p) => toScreen(_rotate(p))).toList();

    return Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();
  }

  void _drawCant(Canvas canvas, Offset Function(Offset) toScreen) {
    final cant = plan.cant;
    if (cant == null) return;

    final path = _rectPath(cant, toScreen);

    canvas.drawPath(
      path,
      Paint()..color = _cantColour.withValues(alpha: 0.18),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = _cantColour,
    );
  }

  void _drawBoards(
    Canvas canvas,
    Offset Function(Offset) toScreen,
    FittedImageMapper mapper,
  ) {
    for (final board in plan.boards) {
      final path = _rectPath(board.rect, toScreen);

      final colour = board.fromCant ? _cantBoardColour : _sideBoardColour;

      canvas.drawPath(path, Paint()..color = colour.withValues(alpha: 0.55));

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.black.withValues(alpha: 0.65),
      );
    }

    if (!showCutNumbers) return;

    // Number the boards so the on-screen pattern and the cut list below it
    // refer to the same pieces.
    for (final board in plan.boards) {
      final centre = toScreen(_rotate(board.rect.center));

      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: "${board.index + 1}",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      )..layout();

      // Skip the label when the board is too small to hold it legibly.
      final screenWidth = mapper.lengthToScreen(board.rect.width / mmPerPixel);

      if (screenWidth < painter.width * 1.8) continue;

      painter.paint(
        canvas,
        Offset(centre.dx - painter.width / 2, centre.dy - painter.height / 2),
      );
    }
  }

  void _drawLegend(Canvas canvas, Size size) {
    final entries = <(Color, String)>[
      if (plan.cant != null) (_cantColour, "Cant (cut this first)"),
      (_cantBoardColour, plan.cant != null ? "Boards from cant" : "Boards"),
      if (plan.boards.any((b) => !b.fromCant))
        (_sideBoardColour, "Side boards"),
    ];

    var y = 10.0;

    for (final (colour, label) in entries) {
      final swatch = Rect.fromLTWH(10, y, 14, 14);

      canvas.drawRect(swatch, Paint()..color = colour.withValues(alpha: 0.75));
      canvas.drawRect(
        swatch,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white70,
      );

      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(blurRadius: 3, color: Colors.black)],
          ),
        ),
      )..layout();

      painter.paint(canvas, Offset(30, y));

      y += 20;
    }
  }

  @override
  bool shouldRepaint(covariant SawingPatternPainter old) {
    return old.plan != plan ||
        old.photo != photo ||
        old.mmPerPixel != mmPerPixel ||
        old.faceOriginPx != faceOriginPx;
  }
}
