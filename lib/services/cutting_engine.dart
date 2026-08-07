import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../models/cutting_models.dart';
import '../models/log_defect.dart';
import '../models/log_face_outline.dart';

/// Packs boards into a log's cross-section.
///
/// Previously this assumed a perfect circle of a single given diameter. That
/// is what the captured photo could never influence: there was nowhere in the
/// model to put a shape. It now packs into a real traced [LogFaceOutline],
/// which changes three things:
///
///  * an oval log is no longer treated as a small round one -- the old code
///    was fed the *thinnest* diameter and discarded everything beyond it,
///    which on a 20x14in log is roughly a third of the face;
///  * concave faces are respected, so a board cannot bridge the dent left
///    where a branch came off;
///  * the best grid angle is searched for. On a circle every angle is
///    identical, so 0/90 was sufficient; on a real outline it is not, and
///    this is where most of the extra yield comes from.
///
/// Defects are optional and additive: with none supplied the result is
/// exactly the shape-aware packing.
class CuttingEngine {
  /// Grid offsets tried per axis. The grid is shifted around inside the face
  /// looking for the placement that catches one more board.
  static const int _offsetSteps = 8;

  /// Angles tried, over 90 degrees. Beyond a quarter turn the arrangement
  /// repeats with width and height swapped, which the orientation loop below
  /// already covers.
  static const int _angleSteps = 12;

  static CuttingResult generate(
    CuttingInput input, {
    LogFaceOutline? outline,
    List<LogDefect> defects = const [],
    bool avoidDefects = false,
  }) {
    // No traced face: fall back to a circle of the measured diameter, so
    // there is one packing path rather than two that can disagree.
    final face = outline ?? LogFaceOutline.circle(input.logDiameter);

    final logArea = face.area;

    if (!face.isValid || logArea <= 0) return _empty(logArea);

    final blocking = avoidDefects
        ? defects.where((d) => d.isDisqualifying).toList()
        : const <LogDefect>[];

    _Arrangement? best;

    for (var step = 0; step < _angleSteps; step++) {
      final angle = (math.pi / 2) * step / _angleSteps;

      // Rotating the face by -angle and packing an upright grid is
      // equivalent to rotating the grid by +angle, and keeps every fit test
      // axis-aligned.
      final rotatedFace = face.rotated(-angle);
      final rotatedDefects = _rotateDefects(blocking, face.centroid, -angle);

      for (final swapped in [false, true]) {
        final w = swapped ? input.boardHeight : input.boardWidth;
        final h = swapped ? input.boardWidth : input.boardHeight;

        final arrangement = _bestArrangementFor(
          face: rotatedFace,
          defects: rotatedDefects,
          boardWidth: w,
          boardHeight: h,
          bladeThickness: input.bladeThickness,
          rotation: (angle * 180 / math.pi) + (swapped ? 90 : 0),
        );

        if (arrangement == null) continue;

        // A board's area is unchanged by swapping its sides, so more boards
        // simply wins. Ties go to the earlier (less rotated) arrangement,
        // which is the easier one to actually cut on a mill.
        if (best == null || arrangement.boards.length > best.boards.length) {
          best = arrangement;
        }
      }
    }

    if (best == null) return _empty(logArea);

    final boardArea = best.boards.length * best.width * best.height;

    final utilization = (boardArea / logArea) * 100;

    return CuttingResult(
      boards: best.boards,
      boardCount: best.boards.length,
      utilization: utilization,
      waste: 100 - utilization,
      profit: best.boards.length * input.boardPrice,
      logArea: logArea,
      boardArea: boardArea,
      wasteArea: math.max(0, logArea - boardArea),
      kerfLoss: _kerfLoss(
        best,
        input.bladeThickness,
        best.width + input.bladeThickness,
        best.height + input.bladeThickness,
      ),
      angle: best.rotation,
      offsetX: best.offsetX,
      offsetY: best.offsetY,
    );
  }

  /// Sawdust actually produced, in area.
  ///
  /// The previous version charged every board a full ring of blade width, as
  /// if each were sawn out in isolation. Two boards side by side share the
  /// cut between them, so that roughly doubled the figure.
  ///
  /// This counts the gaps that genuinely exist: one blade-width strip for
  /// each *adjacent pair* of boards. Counting whole grid lines instead would
  /// swing the error the other way, because a round face only fills the
  /// middle of its bounding grid -- the corner cells hold no boards and cost
  /// no sawdust.
  static double _kerfLoss(
    _Arrangement best,
    double bladeThickness,
    double spacingX,
    double spacingY,
  ) {
    if (best.boards.isEmpty || bladeThickness <= 0) return 0;

    // Snapped to integers: grid positions that are meant to be identical
    // must compare equal despite floating-point accumulation.
    ({int x, int y}) cell(BoardPiece b) => (
          x: (b.x / spacingX).round(),
          y: (b.y / spacingY).round(),
        );

    final occupied = best.boards.map(cell).toSet();

    var sideBySide = 0;
    var stacked = 0;

    for (final c in occupied) {
      if (occupied.contains((x: c.x + 1, y: c.y))) sideBySide++;
      if (occupied.contains((x: c.x, y: c.y + 1))) stacked++;
    }

    // A vertical cut between side-by-side boards is as long as they are
    // tall, and vice versa.
    return bladeThickness *
        (sideBySide * best.height + stacked * best.width);
  }

  static List<LogDefect> _rotateDefects(
    List<LogDefect> defects,
    Offset origin,
    double radians,
  ) {
    if (defects.isEmpty) return const [];

    final cos = math.cos(radians);
    final sin = math.sin(radians);

    return [
      for (final d in defects)
        d.copyWith(
          centre: Offset(
            origin.dx + (d.centre.dx - origin.dx) * cos - (d.centre.dy - origin.dy) * sin,
            origin.dy + (d.centre.dx - origin.dx) * sin + (d.centre.dy - origin.dy) * cos,
          ),
        ),
    ];
  }

  static CuttingResult _empty(double logArea) => CuttingResult(
        boards: const [],
        boardCount: 0,
        utilization: 0,
        waste: 100,
        profit: 0,
        logArea: logArea,
        boardArea: 0,
        wasteArea: logArea,
        kerfLoss: 0,
        angle: 0,
        offsetX: 0,
        offsetY: 0,
      );

  static _Arrangement? _bestArrangementFor({
    required LogFaceOutline face,
    required List<LogDefect> defects,
    required double boardWidth,
    required double boardHeight,
    required double bladeThickness,
    required double rotation,
  }) {
    if (boardWidth <= 0 || boardHeight <= 0) return null;

    final bounds = face.bounds;

    final spacingX = boardWidth + bladeThickness;
    final spacingY = boardHeight + bladeThickness;

    final cols = (bounds.width / spacingX).floor();
    final rows = (bounds.height / spacingY).floor();

    if (cols <= 0 || rows <= 0) return null;

    final gridWidth = cols * boardWidth + (cols - 1) * bladeThickness;
    final gridHeight = rows * boardHeight + (rows - 1) * bladeThickness;

    final slackX = math.max(0.0, bounds.width - gridWidth);
    final slackY = math.max(0.0, bounds.height - gridHeight);

    _Arrangement? best;

    for (var sx = 0; sx <= _offsetSteps; sx++) {
      final startX = bounds.left + slackX * sx / _offsetSteps;

      for (var sy = 0; sy <= _offsetSteps; sy++) {
        final startY = bounds.top + slackY * sy / _offsetSteps;

        final boards = <BoardPiece>[];

        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < cols; c++) {
            final rect = Rect.fromLTWH(
              startX + c * spacingX,
              startY + r * spacingY,
              boardWidth,
              boardHeight,
            );

            if (!face.containsRect(rect)) continue;
            if (defects.any((d) => d.overlaps(rect))) continue;

            boards.add(
              BoardPiece(
                x: rect.left,
                y: rect.top,
                width: boardWidth,
                height: boardHeight,
                rotation: rotation,
                index: boards.length + 1,
              ),
            );
          }
        }

        if (best == null || boards.length > best.boards.length) {
          best = _Arrangement(
            boards: boards,
            width: boardWidth,
            height: boardHeight,
            rotation: rotation,
            offsetX: startX,
            offsetY: startY,
          );
        }
      }
    }

    return best;
  }
}

class _Arrangement {
  final List<BoardPiece> boards;
  final double width;
  final double height;
  final double rotation;
  final double offsetX;
  final double offsetY;

  const _Arrangement({
    required this.boards,
    required this.width,
    required this.height,
    required this.rotation,
    required this.offsetX,
    required this.offsetY,
  });
}
