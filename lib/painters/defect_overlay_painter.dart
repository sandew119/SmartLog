import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/log_defect.dart';
import '../services/defect_impact.dart';
import '../theme/app_theme.dart';
import '../utils/fitted_image_mapper.dart';

/// One defect to draw on the photo.
class OverlayMark {
  /// In photo pixels.
  final Rect region;

  /// Shown on the marker, and matching the numbered list under the photo.
  final int number;

  final String label;
  final Color colour;

  /// A faint finding waiting for a check by eye: drawn dashed.
  final bool pending;

  /// Dismissed by the user: drawn as a ghost, so they can see what they
  /// removed and bring it back.
  final bool dismissed;

  /// The one the user is looking at in the list.
  final bool selected;

  const OverlayMark({
    required this.region,
    required this.number,
    required this.label,
    required this.colour,
    this.pending = false,
    this.dismissed = false,
    this.selected = false,
  });
}

/// Draws what the scan found on top of the photograph it found it in.
///
/// The point is inspectability: a sawmill owner will not act on "this log
/// has a crack" from a box that shows its working to nobody. Each mark is
/// numbered so the photo and the list below it refer to the same defects,
/// and nothing here is a percentage -- a certainty is shown as a solid or a
/// dashed outline, which is all anyone needs to know at a glance.
class DefectOverlayPainter extends CustomPainter {
  final ui.Image photo;
  final Size imageSize;
  final List<OverlayMark> marks;

  /// The traced or auto-found face, in photo pixels, drawn as a faint ring
  /// so the zone labels ("Heart", "Near the bark") have something to refer
  /// to.
  final Offset? faceCentre;
  final double? faceRadius;

  /// Scales strokes and labels for an offscreen render, which is drawn far
  /// larger than the phone screen.
  final double strokeScale;

  DefectOverlayPainter({
    required this.photo,
    required this.imageSize,
    required this.marks,
    this.faceCentre,
    this.faceRadius,
    this.strokeScale = 1,
  });

  static Color colourFor(DefectSeverity severity) => switch (severity) {
        DefectSeverity.low => AppTheme.severityLow,
        DefectSeverity.medium => AppTheme.severityMedium,
        DefectSeverity.high => AppTheme.severityHigh,
      };

  /// A colour by how serious the kind is on its own.
  static Color colourForKind(LogDefectKind kind) {
    if (kind.severity >= 0.9) return AppTheme.severityHigh;
    if (kind.severity >= 0.6) return AppTheme.severityMedium;
    return AppTheme.severityLow;
  }

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

    final anySelected = marks.any((m) => m.selected);

    // Focus: when one mark is selected, the rest of the photo dims so the
    // eye goes straight to it.
    if (anySelected) {
      final selected = marks.firstWhere((m) => m.selected);
      final rect =
          _screenRect(mapper, selected.region).inflate(6 * strokeScale);

      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(display)
        ..addRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(10 * strokeScale)));

      canvas.drawPath(
          path, Paint()..color = Colors.black.withValues(alpha: 0.45));
    }

    _drawFace(canvas, mapper);

    // Dismissed first, so live marks always sit on top of ghosts.
    for (final mark in marks.where((m) => m.dismissed)) {
      _drawMark(canvas, mapper, mark);
    }

    for (final mark in marks.where((m) => !m.dismissed)) {
      _drawMark(canvas, mapper, mark);
    }
  }

  Rect _screenRect(FittedImageMapper mapper, Rect region) => Rect.fromPoints(
        mapper.toScreen(region.topLeft),
        mapper.toScreen(region.bottomRight),
      );

  void _drawFace(Canvas canvas, FittedImageMapper mapper) {
    final centre = faceCentre;
    final radius = faceRadius;
    if (centre == null || radius == null || radius <= 0) return;

    final c = mapper.toScreen(centre);
    final r = mapper.lengthToScreen(radius);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * strokeScale
      ..color = Colors.white.withValues(alpha: 0.55);

    _dashedCircle(canvas, c, r, paint);

    // The heart zone, so "Heart" on a defect card points at something.
    _dashedCircle(
      canvas,
      c,
      r * 0.35,
      paint..color = Colors.white.withValues(alpha: 0.3),
    );
  }

  void _dashedCircle(Canvas canvas, Offset centre, double radius, Paint paint) {
    final circumference = 2 * math.pi * radius;
    final dashes = math.max(12, (circumference / (10 * strokeScale)).floor());

    for (var i = 0; i < dashes; i += 2) {
      final start = 2 * math.pi * i / dashes;
      final sweep = 2 * math.pi / dashes;

      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: radius),
        start,
        sweep,
        false,
        paint,
      );
    }
  }

  void _drawMark(Canvas canvas, FittedImageMapper mapper, OverlayMark mark) {
    final rect = _screenRect(mapper, mark.region);
    final rounded =
        RRect.fromRectAndRadius(rect, Radius.circular(8 * strokeScale));

    final colour = mark.dismissed ? Colors.white : mark.colour;
    final alpha = mark.dismissed ? 0.35 : 1.0;

    if (!mark.dismissed) {
      canvas.drawRRect(
        rounded,
        Paint()..color = colour.withValues(alpha: mark.selected ? 0.18 : 0.1),
      );
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (mark.selected ? 3.2 : 2.4) * strokeScale
      ..color = colour.withValues(alpha: alpha);

    if (mark.pending || mark.dismissed) {
      _dashedRRect(canvas, rounded, stroke);
    } else {
      // A thin dark keyline under the colour keeps the box readable on pale
      // timber and on dark bark alike.
      canvas.drawRRect(
        rounded,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.strokeWidth + 2 * strokeScale
          ..color = Colors.black.withValues(alpha: 0.28),
      );
      canvas.drawRRect(rounded, stroke);
    }

    _drawBadge(canvas, rect, mark, colour, alpha);
  }

  void _dashedRRect(Canvas canvas, RRect rrect, Paint paint) {
    final path = Path()..addRRect(rrect);
    final dash = 7.0 * strokeScale;
    final gap = 5.0 * strokeScale;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;

      while (distance < metric.length) {
        final end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  /// A numbered disc on the corner, and the defect's name beside it.
  void _drawBadge(
    Canvas canvas,
    Rect rect,
    OverlayMark mark,
    Color colour,
    double alpha,
  ) {
    final radius = 11.0 * strokeScale;

    final showLabel = !mark.dismissed;

    final labelPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: mark.label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11 * strokeScale,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    )..layout();

    final numberPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: "${mark.number}",
        style: TextStyle(
          color: mark.dismissed ? Colors.black54 : Colors.white,
          fontSize: 11 * strokeScale,
          fontWeight: FontWeight.w800,
        ),
      ),
    )..layout();

    final pillHeight = radius * 2;
    final pillWidth = showLabel
        ? radius * 2 + labelPainter.width + 12 * strokeScale
        : radius * 2;

    // Above the box, unless that would fall off the top of the picture.
    final above = rect.top - pillHeight - 4 * strokeScale > 0;
    final top = above
        ? rect.top - pillHeight - 4 * strokeScale
        : rect.top + 4 * strokeScale;
    final left = rect.left;

    final pill = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, pillWidth, pillHeight),
      Radius.circular(radius),
    );

    canvas.drawRRect(
      pill.shift(Offset(0, 1.5 * strokeScale)),
      Paint()..color = Colors.black.withValues(alpha: 0.25 * alpha),
    );

    canvas.drawRRect(
      pill,
      Paint()
        ..color = (mark.dismissed ? Colors.white : colour)
            .withValues(alpha: 0.95 * alpha),
    );

    // The number sits in a darker disc at the left end of the pill.
    final disc = Offset(left + radius, top + radius);

    if (showLabel) {
      canvas.drawCircle(
        disc,
        radius - 2 * strokeScale,
        Paint()..color = Colors.black.withValues(alpha: 0.22),
      );
    }

    numberPainter.paint(
      canvas,
      disc - Offset(numberPainter.width / 2, numberPainter.height / 2),
    );

    if (showLabel) {
      labelPainter.paint(
        canvas,
        Offset(
          left + radius * 2 + 4 * strokeScale,
          top + (pillHeight - labelPainter.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant DefectOverlayPainter old) {
    return old.photo != photo ||
        old.marks != marks ||
        old.faceCentre != faceCentre ||
        old.faceRadius != faceRadius ||
        old.strokeScale != strokeScale;
  }
}
