import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../models/log_face_outline.dart';
import '../models/sawing_models.dart';
import '../utils/log_face_mask.dart';

/// Plans how to break a log down into boards.
///
/// Two things separate this from the engine it replaces. It knows that a log
/// is squared into a **cant** before it is resawn, which is how mills
/// actually work and what the sawyer physically does first. And it scores on
/// **volume**, not board count -- once widths vary, counting boards rewards
/// cutting many narrow ones, which is the opposite of what a yard wants.
class SawingEngine {
  /// Millimetres cubed in a cubic foot.
  static const double _mm3PerCubicFoot = 304.8 * 304.8 * 304.8;

  /// Pattern rotations tried, spread over a half turn.
  ///
  /// A half turn rather than a quarter because a log face is not
  /// symmetric -- the flat side left by a previous cut, or the dent where a
  /// branch came off, makes 10 degrees and 100 degrees genuinely different.
  static const int _angleSteps = 12;

  /// Positions tried for the cut pattern within one board pitch.
  static const int _phaseSteps = 8;

  /// Cell count along the face's longer side. About 2 mm per cell on a
  /// 500 mm log -- finer than any kerf, and the erosion inside the mask
  /// keeps the error on the safe side.
  static const int _maskResolution = 220;

  /// Plans both strategies so the caller can show them side by side.
  static SawingComparison planBoth(SawingRequest request) {
    if (!request.isValid) return const SawingComparison();

    return SawingComparison(
      cant: planCant(request),
      live: planLive(request),
    );
  }

  // --- Cant sawing --------------------------------------------------------

  /// Squares the log into a block, then fills the block with boards and
  /// takes what it can off the rounded outside.
  static SawPlan? planCant(SawingRequest request) {
    if (!request.isValid) return null;

    SawPlan? best;

    for (var i = 0; i < _angleSteps; i++) {
      final angle = math.pi * i / _angleSteps;

      final context = _RotatedFace.build(request, angle);
      if (context == null) continue;

      for (final swapped in _orientations(request)) {
        final plan = _packCant(request, context, swapped);
        if (plan == null) continue;

        if (best == null ||
            plan.boardVolumeCubicFeet > best.boardVolumeCubicFeet) {
          best = plan;
        }
      }
    }

    return best;
  }

  static SawPlan? _packCant(
    SawingRequest request,
    _RotatedFace face,
    bool swapped,
  ) {
    final kerf = request.kerfMm;

    final thickness = swapped
        ? (request.boardWidthMm ?? request.boardThicknessMm)
        : request.boardThicknessMm;

    final width = swapped ? request.boardThicknessMm : request.boardWidthMm;

    if (thickness <= 0) return null;

    final pitch = thickness + kerf;

    Rect? bestCant;
    var bestRows = 0;

    // A cant holding N rows must be N*thickness plus the kerfs between them.
    // Trying each row count directly is exact, and cheap enough now that a
    // fit test is four array lookups.
    for (var rows = 1; rows <= 200; rows++) {
      final cantHeight = rows * pitch - kerf;
      if (cantHeight > face.mask.rows * face.mask.cellSize) break;

      final candidate = face.mask.widestRectOfHeight(cantHeight);
      if (candidate == null) continue;

      if (bestCant == null ||
          _cantScore(candidate, request, width, kerf) >
              _cantScore(bestCant, request, width, kerf)) {
        bestCant = candidate;
        bestRows = rows;
      }
    }

    if (bestCant == null || bestRows == 0) return null;

    final boards = <SawnBoard>[];
    final cuts = <SawCut>[];

    var index = 0;

    // The two cuts that make the block. These come first for a reason: the
    // sawyer cannot do anything else until the log has a flat face.
    cuts.add(SawCut(
      order: cuts.length + 1,
      setback: bestCant.top,
      description: "Slab off the first face at "
          "${bestCant.top.toStringAsFixed(0)} mm to open the log",
      definesCant: true,
    ));
    cuts.add(SawCut(
      order: cuts.length + 1,
      setback: bestCant.bottom,
      description: "Turn 180 deg and slab the opposite face, leaving a "
          "${bestCant.height.toStringAsFixed(0)} mm cant",
      definesCant: true,
    ));

    for (var row = 0; row < bestRows; row++) {
      final top = bestCant.top + row * (thickness + kerf);
      final rowRect = Rect.fromLTWH(
        bestCant.left,
        top,
        bestCant.width,
        thickness,
      );

      for (final board in _boardsAcross(rowRect, width, kerf, request)) {
        boards.add(SawnBoard(
          rect: board,
          index: index++,
          fromCant: true,
        ));
      }

      if (row < bestRows - 1) {
        cuts.add(SawCut(
          order: cuts.length + 1,
          setback: top + thickness,
          description: "Resaw at ${(top + thickness).toStringAsFixed(0)} mm",
        ));
      }
    }

    // Side boards off the rounded slabs the cant left behind. Real mills
    // recover these rather than sending them straight to the chipper.
    final sideBoards = _sideBoards(
      request: request,
      face: face,
      cant: bestCant,
      thickness: thickness,
      width: width,
      startIndex: index,
    );

    boards.addAll(sideBoards);

    if (boards.isEmpty) return null;

    return _assemble(
      request: request,
      face: face,
      boards: boards,
      cant: bestCant,
      cuts: cuts,
      strategy: SawingStrategy.cant,
    );
  }

  /// Rough merit of a cant before its boards are laid out, used only to
  /// choose between candidates cheaply.
  static double _cantScore(
    Rect cant,
    SawingRequest request,
    double? width,
    double kerf,
  ) {
    if (request.mode == SawingMode.fixedThickness) {
      return cant.width * cant.height;
    }

    if (width == null || width <= 0) return 0;

    final across = ((cant.width + kerf) / (width + kerf)).floor();
    return across * width * cant.height;
  }

  /// Lays boards across one row of the cant.
  static List<Rect> _boardsAcross(
    Rect row,
    double? width,
    double kerf,
    SawingRequest request,
  ) {
    // Fixed-thickness: the row is one board as wide as the cant allows,
    // snapped to a saleable width.
    if (request.mode == SawingMode.fixedThickness || width == null) {
      final usable = _snapWidth(row.width, request);
      if (usable < request.minBoardWidthMm) return const [];

      final rect = Rect.fromLTWH(row.left, row.top, usable, row.height);
      return _passesDefects(rect, request) ? [rect] : const [];
    }

    final count = ((row.width + kerf) / (width + kerf)).floor();
    if (count <= 0) return const [];

    // Centre the run so the leftover is shared between both edges.
    final span = count * width + (count - 1) * kerf;
    final startX = row.left + (row.width - span) / 2;

    final rects = <Rect>[];
    for (var i = 0; i < count; i++) {
      final rect = Rect.fromLTWH(
        startX + i * (width + kerf),
        row.top,
        width,
        row.height,
      );

      if (_passesDefects(rect, request)) rects.add(rect);
    }

    return rects;
  }

  /// Boards recovered from the curved slabs left above and below the cant.
  static List<SawnBoard> _sideBoards({
    required SawingRequest request,
    required _RotatedFace face,
    required Rect cant,
    required double thickness,
    required double? width,
    required int startIndex,
  }) {
    final kerf = request.kerfMm;
    final boards = <SawnBoard>[];

    var index = startIndex;

    // Work outward from each face of the cant until the log runs out.
    for (final goingUp in [true, false]) {
      var edge = goingUp ? cant.top - kerf : cant.bottom + kerf;

      for (var slab = 0; slab < 40; slab++) {
        final top = goingUp ? edge - thickness : edge;
        final bottom = top + thickness;

        final run = face.mask.widestRunInBand(top, bottom);
        if (run == null) break;

        final available = run.right - run.left;
        if (available < request.minBoardWidthMm) break;

        final rowRect = Rect.fromLTRB(run.left, top, run.right, bottom);

        for (final rect in _boardsAcross(rowRect, width, kerf, request)) {
          boards.add(SawnBoard(rect: rect, index: index++, fromCant: false));
        }

        edge = goingUp ? top - kerf : bottom + kerf;
      }
    }

    return boards;
  }

  // --- Live sawing --------------------------------------------------------

  /// Cuts straight through without turning the log.
  static SawPlan? planLive(SawingRequest request) {
    if (!request.isValid) return null;

    SawPlan? best;

    for (var i = 0; i < _angleSteps; i++) {
      final angle = math.pi * i / _angleSteps;

      final context = _RotatedFace.build(request, angle);
      if (context == null) continue;

      for (final swapped in _orientations(request)) {
        final thickness = swapped
            ? (request.boardWidthMm ?? request.boardThicknessMm)
            : request.boardThicknessMm;

        final width = swapped ? request.boardThicknessMm : request.boardWidthMm;

        final pitch = thickness + request.kerfMm;
        if (pitch <= 0) continue;

        for (var p = 0; p < _phaseSteps; p++) {
          final phase = pitch * p / _phaseSteps;

          final plan = _packLive(request, context, thickness, width, phase);
          if (plan == null) continue;

          if (best == null ||
              plan.boardVolumeCubicFeet > best.boardVolumeCubicFeet) {
            best = plan;
          }
        }
      }
    }

    return best;
  }

  static SawPlan? _packLive(
    SawingRequest request,
    _RotatedFace face,
    double thickness,
    double? width,
    double phase,
  ) {
    final kerf = request.kerfMm;
    final pitch = thickness + kerf;

    final faceTop = face.mask.origin.dy;
    final faceBottom = faceTop + face.mask.rows * face.mask.cellSize;

    final boards = <SawnBoard>[];
    final cuts = <SawCut>[];

    var index = 0;
    var top = faceTop + phase;

    while (top + thickness <= faceBottom) {
      final bottom = top + thickness;

      final run = face.mask.widestRunInBand(top, bottom);

      if (run != null && (run.right - run.left) >= request.minBoardWidthMm) {
        final rowRect = Rect.fromLTRB(run.left, top, run.right, bottom);

        for (final rect in _boardsAcross(rowRect, width, kerf, request)) {
          boards.add(SawnBoard(rect: rect, index: index++, fromCant: false));
        }

        cuts.add(SawCut(
          order: cuts.length + 1,
          setback: top,
          description: "Cut through at ${top.toStringAsFixed(0)} mm",
        ));
      }

      top += pitch;
    }

    if (boards.isEmpty) return null;

    return _assemble(
      request: request,
      face: face,
      boards: boards,
      cant: null,
      cuts: cuts,
      strategy: SawingStrategy.live,
    );
  }

  // --- shared -------------------------------------------------------------

  /// In fixed-thickness mode there is no second dimension to swap, so trying
  /// both orientations would just double the work for the same answer.
  static List<bool> _orientations(SawingRequest request) =>
      request.mode == SawingMode.fixedThickness
          ? const [false]
          : const [false, true];

  /// Rounds a width down to a size the mill actually sells.
  static double _snapWidth(double raw, SawingRequest request) {
    final increment = request.widthIncrementMm;
    if (increment == null || increment <= 0) return raw;

    return (raw / increment).floor() * increment;
  }

  static bool _passesDefects(Rect rect, SawingRequest request) {
    if (!request.avoidDefects || request.defects.isEmpty) return true;

    for (final defect in request.defects) {
      if (defect.isDisqualifying && defect.overlaps(rect)) return false;
    }

    return true;
  }

  static SawPlan _assemble({
    required SawingRequest request,
    required _RotatedFace face,
    required List<SawnBoard> boards,
    required Rect? cant,
    required List<SawCut> cuts,
    required SawingStrategy strategy,
  }) {
    var boardArea = 0.0;
    for (final board in boards) {
      boardArea += board.rect.width * board.rect.height;
    }

    final logArea = face.rotated.area;

    // Everything the blade turned into sawdust: one kerf per cut line
    // across the timber it actually passed through.
    var kerfArea = 0.0;
    for (final cut in cuts) {
      final run = face.mask.widestRunInBand(
        cut.setback,
        cut.setback + request.kerfMm,
      );
      if (run != null) kerfArea += (run.right - run.left) * request.kerfMm;
    }

    // Whatever is neither board nor sawdust went out as slab and edgings.
    final edgingArea = math.max(0.0, logArea - boardArea - kerfArea);

    final boardVolume = boardArea * request.logLengthMm / _mm3PerCubicFoot;
    final logVolume = logArea * request.logLengthMm / _mm3PerCubicFoot;

    return SawPlan(
      strategy: strategy,
      outline: request.outline,
      boards: boards,
      cant: cant,
      patternAngle: face.angle,
      rotationCentre: request.outline.centroid,
      logLengthMm: request.logLengthMm,
      boardVolumeCubicFeet: boardVolume,
      logVolumeCubicFeet: logVolume,
      kerfAreaMm2: kerfArea,
      edgingAreaMm2: edgingArea,
      cuts: cuts,
      pricePerCubicFoot: request.pricePerCubicFoot,
    );
  }
}

/// The face turned to one trial angle, rasterised ready to pack.
///
/// Rotation is about the outline's centroid, which rotation leaves fixed, so
/// a board found here maps back onto the photograph by turning it the same
/// amount about the same point.
class _RotatedFace {
  final double angle;
  final LogFaceOutline rotated;
  final LogFaceMask mask;

  const _RotatedFace({
    required this.angle,
    required this.rotated,
    required this.mask,
  });

  static _RotatedFace? build(SawingRequest request, double angle) {
    final rotated =
        angle == 0 ? request.outline : request.outline.rotated(-angle);

    final mask = LogFaceMask.fromOutline(
      rotated,
      resolution: SawingEngine._maskResolution,
    );

    if (mask == null) return null;

    return _RotatedFace(angle: angle, rotated: rotated, mask: mask);
  }
}

/// Turns a board from the pattern frame back into the photograph's frame.
///
/// Kept beside the engine so the painter and the engine can never disagree
/// about which way the pattern turns.
List<Offset> boardCornersInFaceFrame(SawPlan plan, SawnBoard board) {
  final c = math.cos(plan.patternAngle);
  final s = math.sin(plan.patternAngle);
  final o = plan.rotationCentre;

  Offset rotate(Offset p) => Offset(
        o.dx + (p.dx - o.dx) * c - (p.dy - o.dy) * s,
        o.dy + (p.dx - o.dx) * s + (p.dy - o.dy) * c,
      );

  return [
    rotate(board.rect.topLeft),
    rotate(board.rect.topRight),
    rotate(board.rect.bottomRight),
    rotate(board.rect.bottomLeft),
  ];
}
