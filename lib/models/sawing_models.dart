import 'dart:ui' show Offset, Rect;

import 'log_defect.dart';
import 'log_face_outline.dart';

/// What the mill has decided in advance.
enum SawingMode {
  /// Every board is the same known size. The mill has an order to fill.
  fixedSize,

  /// Only the thickness is fixed; width is whatever the log will give.
  ///
  /// This is the common case for a yard cutting one product all day: they
  /// want the most timber out of the log and will edge the boards to
  /// whatever widths fall out.
  fixedThickness,
}

/// How the log is broken down.
enum SawingStrategy {
  /// Square the log into a cant first, then resaw the cant into boards.
  /// Dominant in mills producing dimensional timber.
  cant,

  /// Cut straight through, parallel, without turning the log. Simpler and
  /// often higher volume, but yields wider and narrower boards mixed.
  live,
}

extension SawingStrategyLabel on SawingStrategy {
  String get label => switch (this) {
        SawingStrategy.cant => "Cant sawing",
        SawingStrategy.live => "Live sawing",
      };

  String get explanation => switch (this) {
        SawingStrategy.cant =>
          "Square the log into a block first, then saw the block into "
              "boards. Boards come out uniform and square-edged.",
        SawingStrategy.live =>
          "Saw straight through the log without turning it. Fewer handling "
              "steps and often more timber, but board widths vary.",
      };
}

/// One board in a plan, in the pattern's own (rotated) frame.
class SawnBoard {
  final Rect rect;

  /// True when the board comes out of the squared cant rather than off the
  /// rounded outside of the log.
  final bool fromCant;

  final int index;

  const SawnBoard({
    required this.rect,
    required this.index,
    this.fromCant = true,
  });

  double get width => rect.width;
  double get thickness => rect.height;
}

/// A single pass of the saw, in the order a sawyer would make it.
class SawCut {
  final int order;

  /// Distance from the reference face, in the same units as the outline.
  /// This is the number the sawyer sets the fence to.
  final double setback;

  final String description;

  /// Cuts that define the cant, as opposed to resawing it into boards.
  final bool definesCant;

  const SawCut({
    required this.order,
    required this.setback,
    required this.description,
    this.definesCant = false,
  });
}

/// A complete breakdown of one log.
class SawPlan {
  final SawingStrategy strategy;

  /// The face that was packed, in millimetres.
  ///
  /// The old `CuttingResult` carried only numbers, which is exactly why the
  /// pattern had to be drawn inside a generic circle. Carrying the outline
  /// lets the pattern be drawn on the real photographed shape.
  final LogFaceOutline outline;

  /// The squared block, if this strategy makes one. Drawn in its own colour
  /// because it is the first thing the sawyer actually cuts.
  final Rect? cant;

  final List<SawnBoard> boards;

  /// Rotation of the whole pattern, in radians.
  final double patternAngle;

  /// Point the pattern rotates about -- the outline's centroid, which
  /// rotation leaves fixed.
  final Offset rotationCentre;

  final double logLengthMm;

  final double boardVolumeCubicFeet;
  final double logVolumeCubicFeet;

  /// Cross-sectional area lost to the saw itself, in mm².
  final double kerfAreaMm2;

  /// Cross-sectional area lost trimming waney edges square, in mm².
  final double edgingAreaMm2;

  final List<SawCut> cuts;

  final double pricePerCubicFoot;

  const SawPlan({
    required this.strategy,
    required this.outline,
    required this.boards,
    required this.patternAngle,
    required this.rotationCentre,
    required this.logLengthMm,
    required this.boardVolumeCubicFeet,
    required this.logVolumeCubicFeet,
    required this.kerfAreaMm2,
    required this.edgingAreaMm2,
    required this.cuts,
    this.cant,
    this.pricePerCubicFoot = 0,
  });

  int get boardCount => boards.length;

  /// Fraction of the log that leaves as saleable timber.
  double get yieldPercent => logVolumeCubicFeet <= 0
      ? 0
      : (boardVolumeCubicFeet / logVolumeCubicFeet) * 100;

  double get value => boardVolumeCubicFeet * pricePerCubicFoot;

  /// A proxy for time and blade wear: mills care about this, not just yield.
  int get sawPasses => cuts.length;

  /// Widths present in the plan, ascending. In fixed-thickness mode these
  /// vary, which is the whole reason yield is scored on volume rather than
  /// board count.
  List<double> get distinctWidths {
    final widths = boards.map((b) => b.width.roundToDouble()).toSet().toList()
      ..sort();
    return widths;
  }

  SawPlan copyWithPrice(double price) => SawPlan(
        strategy: strategy,
        outline: outline,
        boards: boards,
        patternAngle: patternAngle,
        rotationCentre: rotationCentre,
        logLengthMm: logLengthMm,
        boardVolumeCubicFeet: boardVolumeCubicFeet,
        logVolumeCubicFeet: logVolumeCubicFeet,
        kerfAreaMm2: kerfAreaMm2,
        edgingAreaMm2: edgingAreaMm2,
        cuts: cuts,
        cant: cant,
        pricePerCubicFoot: price,
      );
}

/// Everything the engine needs to plan a log.
class SawingRequest {
  /// Face outline in millimetres, positioned in the first quadrant.
  final LogFaceOutline outline;

  final double logLengthMm;

  /// Saw kerf -- the timber the blade turns into sawdust on every pass.
  final double kerfMm;

  final SawingMode mode;

  /// Always meaningful: in fixed-size mode it is the board's smaller
  /// dimension, in fixed-thickness mode it is the only dimension given.
  final double boardThicknessMm;

  /// Only in [SawingMode.fixedSize].
  final double? boardWidthMm;

  /// Below this a piece is slab waste, not a board. Mills have an edger
  /// limit and a width nobody will buy.
  final double minBoardWidthMm;

  /// Snap board widths down to a multiple of this, when the mill sells in
  /// standard widths. Null means take whatever the log gives.
  final double? widthIncrementMm;

  final double pricePerCubicFoot;

  final List<LogDefect> defects;
  final bool avoidDefects;

  const SawingRequest({
    required this.outline,
    required this.logLengthMm,
    required this.boardThicknessMm,
    this.kerfMm = 3,
    this.mode = SawingMode.fixedSize,
    this.boardWidthMm,
    this.minBoardWidthMm = 50,
    this.widthIncrementMm,
    this.pricePerCubicFoot = 0,
    this.defects = const [],
    this.avoidDefects = false,
  });

  bool get isValid =>
      outline.isValid &&
      logLengthMm > 0 &&
      boardThicknessMm > 0 &&
      kerfMm >= 0 &&
      (mode == SawingMode.fixedThickness ||
          (boardWidthMm != null && boardWidthMm! > 0));
}

/// What the user chose in the setup sheet, before an outline is attached.
///
/// Separate from [SawingRequest] because the sheet has no idea what shape
/// the log is -- that comes from the trace or the sensor -- and keeping the
/// two apart means the sheet can be filled in before or after measuring.
class SawingSetup {
  final double logDiameterMm;
  final double logLengthMm;

  final SawingMode mode;
  final double boardThicknessMm;
  final double? boardWidthMm;
  final double minBoardWidthMm;
  final double? widthIncrementMm;

  final double kerfMm;
  final double pricePerCubicFoot;

  const SawingSetup({
    required this.logDiameterMm,
    required this.logLengthMm,
    required this.boardThicknessMm,
    this.mode = SawingMode.fixedSize,
    this.boardWidthMm,
    this.minBoardWidthMm = 50,
    this.widthIncrementMm,
    this.kerfMm = 3,
    this.pricePerCubicFoot = 0,
  });

  /// Attaches a face and produces something the engine can plan.
  SawingRequest toRequest(
    LogFaceOutline outline, {
    List<LogDefect> defects = const [],
    bool avoidDefects = false,
  }) {
    return SawingRequest(
      outline: outline,
      logLengthMm: logLengthMm,
      boardThicknessMm: boardThicknessMm,
      boardWidthMm: boardWidthMm,
      minBoardWidthMm: minBoardWidthMm,
      widthIncrementMm: widthIncrementMm,
      kerfMm: kerfMm,
      mode: mode,
      pricePerCubicFoot: pricePerCubicFoot,
      defects: defects,
      avoidDefects: avoidDefects,
    );
  }
}

/// Both strategies costed, so the sawyer can choose on their own terms
/// rather than being handed one answer.
class SawingComparison {
  final SawPlan? cant;
  final SawPlan? live;

  const SawingComparison({this.cant, this.live});

  bool get hasAny => cant != null || live != null;

  /// Whichever yields more timber. Presented as a recommendation, not a
  /// decision -- a mill without a resaw simply cannot cut a cant.
  SawPlan? get best {
    if (cant == null) return live;
    if (live == null) return cant;

    return live!.boardVolumeCubicFeet > cant!.boardVolumeCubicFeet
        ? live
        : cant;
  }

  List<SawPlan> get plans => [
        if (cant != null) cant!,
        if (live != null) live!,
      ];
}
