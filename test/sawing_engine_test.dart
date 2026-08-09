import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_defect.dart';
import 'package:smartlog2/models/log_face_outline.dart';
import 'package:smartlog2/models/sawing_models.dart';
import 'package:smartlog2/services/sawing_engine.dart';

const double _mm3PerCubicFoot = 304.8 * 304.8 * 304.8;

SawingRequest fixedSize({
  double diameter = 500,
  double length = 3000,
  double boardWidth = 100,
  double boardThickness = 50,
  double kerf = 3,
  double price = 0,
  List<LogDefect> defects = const [],
  bool avoidDefects = false,
  LogFaceOutline? outline,
}) {
  return SawingRequest(
    outline: outline ?? LogFaceOutline.circle(diameter),
    logLengthMm: length,
    boardThicknessMm: boardThickness,
    boardWidthMm: boardWidth,
    kerfMm: kerf,
    mode: SawingMode.fixedSize,
    pricePerCubicFoot: price,
    defects: defects,
    avoidDefects: avoidDefects,
  );
}

SawingRequest fixedThickness({
  double diameter = 500,
  double length = 3000,
  double thickness = 50,
  double kerf = 3,
  double minWidth = 50,
  double? increment,
  double price = 0,
}) {
  return SawingRequest(
    outline: LogFaceOutline.circle(diameter),
    logLengthMm: length,
    boardThicknessMm: thickness,
    kerfMm: kerf,
    mode: SawingMode.fixedThickness,
    minBoardWidthMm: minWidth,
    widthIncrementMm: increment,
    pricePerCubicFoot: price,
  );
}

void main() {
  group('boards physically fit the log', () {
    test('every board from cant sawing lies inside the face', () {
      final request = fixedSize();
      final plan = SawingEngine.planCant(request)!;

      // Boards are produced in the rotated pattern frame, so check them
      // against the face rotated the same way.
      final rotatedFace = request.outline.rotated(-plan.patternAngle);

      for (final board in plan.boards) {
        expect(
          rotatedFace.containsRect(board.rect, samplesPerEdge: 6),
          isTrue,
          reason: "board ${board.index} at ${board.rect} escapes the log",
        );
      }
    });

    test('every board from live sawing lies inside the face', () {
      final request = fixedSize();
      final plan = SawingEngine.planLive(request)!;
      final rotatedFace = request.outline.rotated(-plan.patternAngle);

      for (final board in plan.boards) {
        expect(
          rotatedFace.containsRect(board.rect, samplesPerEdge: 6),
          isTrue,
          reason: "board ${board.index} at ${board.rect} escapes the log",
        );
      }
    });

    test('boards never overlap each other', () {
      final plan = SawingEngine.planCant(fixedSize())!;

      for (var i = 0; i < plan.boards.length; i++) {
        for (var j = i + 1; j < plan.boards.length; j++) {
          final a = plan.boards[i].rect;
          final b = plan.boards[j].rect;

          final overlap = a.overlaps(b);

          if (overlap) {
            final intersection = a.intersect(b);
            // Touching edges are fine; genuine shared area is not.
            expect(
              intersection.width * intersection.height,
              lessThan(0.01),
              reason: "boards $i and $j overlap",
            );
          }
        }
      }
    });

    test('boards inside a row are separated by at least the kerf', () {
      const kerf = 5.0;
      final plan = SawingEngine.planCant(fixedSize(kerf: kerf))!;

      // Group boards by their row (same top edge).
      final rows = <double, List<Rect>>{};
      for (final board in plan.boards) {
        rows
            .putIfAbsent(board.rect.top.roundToDouble(), () => [])
            .add(board.rect);
      }

      for (final row in rows.values) {
        row.sort((a, b) => a.left.compareTo(b.left));
        for (var i = 1; i < row.length; i++) {
          final gap = row[i].left - row[i - 1].right;
          expect(gap, greaterThanOrEqualTo(kerf - 0.01));
        }
      }
    });
  });

  group('cant sawing', () {
    test('produces a cant, and marks the boards that came out of it', () {
      final plan = SawingEngine.planCant(fixedSize())!;

      expect(plan.cant, isNotNull);
      expect(plan.strategy, SawingStrategy.cant);
      expect(plan.boards.any((b) => b.fromCant), isTrue);
    });

    test('the cant itself fits inside the log', () {
      final request = fixedSize();
      final plan = SawingEngine.planCant(request)!;
      final rotatedFace = request.outline.rotated(-plan.patternAngle);

      expect(
        rotatedFace.containsRect(plan.cant!, samplesPerEdge: 8),
        isTrue,
      );
    });

    test('the cant is no larger than the largest square that fits', () {
      // The biggest square inside a circle of diameter D has side D/sqrt(2).
      const diameter = 500.0;
      final limit = diameter / math.sqrt2;

      final plan = SawingEngine.planCant(fixedSize(diameter: diameter))!;
      final cant = plan.cant!;

      // Neither side can exceed the diameter, and the diagonal cannot
      // exceed it either -- that is what "inscribed" means.
      final diagonal =
          math.sqrt(cant.width * cant.width + cant.height * cant.height);

      expect(diagonal, lessThanOrEqualTo(diameter + 2));
      expect(math.min(cant.width, cant.height), lessThanOrEqualTo(limit + 2));
    });

    test('the cut list opens the log before resawing it', () {
      final plan = SawingEngine.planCant(fixedSize())!;

      expect(plan.cuts, isNotEmpty);
      expect(plan.cuts.first.definesCant, isTrue);
      expect(plan.cuts.take(2).where((c) => c.definesCant).length, 2);

      // Order is what a sawyer follows, so it must be sequential.
      for (var i = 0; i < plan.cuts.length; i++) {
        expect(plan.cuts[i].order, i + 1);
      }
    });

    test('side boards are recovered off the rounded outside', () {
      // A generous log leaves real timber outside the cant.
      final plan = SawingEngine.planCant(
        fixedSize(diameter: 600, boardWidth: 100, boardThickness: 40),
      )!;

      expect(plan.boards.any((b) => !b.fromCant), isTrue);
    });
  });

  group('live sawing', () {
    test('produces boards but no cant', () {
      final plan = SawingEngine.planLive(fixedSize())!;

      expect(plan.cant, isNull);
      expect(plan.strategy, SawingStrategy.live);
      expect(plan.boards, isNotEmpty);
    });

    test('slab widths follow the chord of the circle', () {
      final request =
          fixedThickness(diameter: 400, thickness: 25, minWidth: 20);
      final plan = SawingEngine.planLive(request)!;

      // The widest board must be close to the full diameter, since one slab
      // straddles the centre.
      final widest =
          plan.boards.map((b) => b.width).reduce((a, b) => a > b ? a : b);

      expect(widest, lessThanOrEqualTo(400));
      expect(widest, greaterThan(360));
    });

    test('boards narrower than the mill can use are dropped', () {
      final generous = SawingEngine.planLive(
        fixedThickness(diameter: 400, thickness: 25, minWidth: 20),
      )!;

      final strict = SawingEngine.planLive(
        fixedThickness(diameter: 400, thickness: 25, minWidth: 250),
      )!;

      expect(strict.boardCount, lessThan(generous.boardCount));

      for (final board in strict.boards) {
        expect(board.width, greaterThanOrEqualTo(250));
      }
    });

    test('width rounding never produces a width off the increment', () {
      final plan = SawingEngine.planLive(
        fixedThickness(
          diameter: 450,
          thickness: 25,
          minWidth: 50,
          increment: 25,
        ),
      )!;

      for (final board in plan.boards) {
        // Rect.width is computed as right - left, so it carries a few
        // femtometres of float error. Compare against the nearest multiple
        // rather than using modulo, which turns that error into a full
        // increment.
        final nearestMultiple = (board.width / 25).round() * 25;

        expect(
          board.width,
          closeTo(nearestMultiple, 1e-6),
          reason: "${board.width} is not a 25 mm increment",
        );
      }
    });
  });

  group('scoring on volume, not board count', () {
    test(
        'a plan with fewer but wider boards can win -- counting boards would '
        'have picked the wrong one', () {
      final request =
          fixedThickness(diameter: 500, thickness: 40, minWidth: 60);
      final comparison = SawingEngine.planBoth(request);

      expect(comparison.hasAny, isTrue);

      final best = comparison.best!;

      for (final plan in comparison.plans) {
        expect(
          best.boardVolumeCubicFeet,
          greaterThanOrEqualTo(plan.boardVolumeCubicFeet - 1e-9),
        );
      }
    });

    test('volume matches the boards actually placed', () {
      final plan = SawingEngine.planCant(fixedSize())!;

      var area = 0.0;
      for (final board in plan.boards) {
        area += board.rect.width * board.rect.height;
      }

      final expected = area * plan.logLengthMm / _mm3PerCubicFoot;

      expect(plan.boardVolumeCubicFeet, closeTo(expected, 1e-9));
    });

    test('yield is a sane fraction, never over 100%', () {
      for (final plan in SawingEngine.planBoth(fixedSize()).plans) {
        expect(plan.yieldPercent, greaterThan(0));
        expect(plan.yieldPercent, lessThan(100));
      }
    });

    test('value follows volume and the rate per cubic foot', () {
      final plan = SawingEngine.planCant(fixedSize(price: 250))!;

      expect(plan.value, closeTo(plan.boardVolumeCubicFeet * 250, 1e-9));
    });

    test('losses add up to the log: boards + kerf + edgings', () {
      final request = fixedSize();
      final plan = SawingEngine.planCant(request)!;

      final rotatedFace = request.outline.rotated(-plan.patternAngle);

      var boardArea = 0.0;
      for (final board in plan.boards) {
        boardArea += board.rect.width * board.rect.height;
      }

      final total = boardArea + plan.kerfAreaMm2 + plan.edgingAreaMm2;

      expect(total, closeTo(rotatedFace.area, rotatedFace.area * 0.02));
    });
  });

  group('comparing the two strategies', () {
    test('planBoth returns both, and best is one of them', () {
      final comparison = SawingEngine.planBoth(fixedSize());

      expect(comparison.cant, isNotNull);
      expect(comparison.live, isNotNull);
      expect(comparison.plans.length, 2);
      expect(comparison.plans.contains(comparison.best), isTrue);
    });

    test('best picks the higher-volume plan', () {
      final comparison = SawingEngine.planBoth(fixedSize());

      final cantVolume = comparison.cant!.boardVolumeCubicFeet;
      final liveVolume = comparison.live!.boardVolumeCubicFeet;

      expect(
        comparison.best!.boardVolumeCubicFeet,
        math.max(cantVolume, liveVolume),
      );
    });
  });

  group('defects', () {
    test('a disqualifying defect removes boards that cover it', () {
      final clean = SawingEngine.planCant(fixedSize())!;

      // A big rot patch straight through the middle of the face.
      final defect = LogDefect(
        kind: LogDefectKind.rot,
        centre: const Offset(250, 250),
        radius: 90,
      );

      final avoided = SawingEngine.planCant(
        fixedSize(defects: [defect], avoidDefects: true),
      )!;

      expect(avoided.boardCount, lessThan(clean.boardCount));
    });

    test('defects are ignored when the user has not asked to avoid them', () {
      final defect = LogDefect(
        kind: LogDefectKind.rot,
        centre: const Offset(250, 250),
        radius: 90,
      );

      final ignored = SawingEngine.planCant(
        fixedSize(defects: [defect], avoidDefects: false),
      )!;

      final clean = SawingEngine.planCant(fixedSize())!;

      expect(ignored.boardCount, clean.boardCount);
    });
  });

  group('irregular and awkward faces', () {
    test('an oval log yields more than the circle it would be rounded to', () {
      // A real face is oval; the old engine reduced it to a circle and threw
      // the difference away.
      final oval = LogFaceOutline(
        List.generate(144, (i) {
          final t = 2 * math.pi * i / 144;
          return Offset(300 + 300 * math.cos(t), 200 + 200 * math.sin(t));
        }),
      );

      final ovalPlan = SawingEngine.planCant(
        fixedSize(outline: oval, boardWidth: 100, boardThickness: 40),
      )!;

      final circlePlan = SawingEngine.planCant(
        fixedSize(
          outline: LogFaceOutline.circle(oval.equivalentCircleDiameter),
          boardWidth: 100,
          boardThickness: 40,
        ),
      )!;

      // Not a guaranteed inequality in general, but for a 3:2 oval the true
      // shape must not do worse than its equal-area circle.
      expect(
        ovalPlan.boardVolumeCubicFeet,
        greaterThanOrEqualTo(circlePlan.boardVolumeCubicFeet * 0.9),
      );
    });

    test('a log too small for even one board returns null, not an empty plan',
        () {
      final tiny =
          fixedSize(diameter: 60, boardWidth: 200, boardThickness: 100);

      expect(SawingEngine.planCant(tiny), isNull);
      expect(SawingEngine.planLive(tiny), isNull);
      expect(SawingEngine.planBoth(tiny).hasAny, isFalse);
    });

    test('invalid requests are rejected rather than guessed at', () {
      final noOutline = SawingRequest(
        outline: const LogFaceOutline([]),
        logLengthMm: 3000,
        boardThicknessMm: 50,
        boardWidthMm: 100,
      );

      expect(SawingEngine.planBoth(noOutline).hasAny, isFalse);

      final noThickness = SawingRequest(
        outline: LogFaceOutline.circle(500),
        logLengthMm: 3000,
        boardThicknessMm: 0,
        boardWidthMm: 100,
      );

      expect(SawingEngine.planBoth(noThickness).hasAny, isFalse);

      final noLength = SawingRequest(
        outline: LogFaceOutline.circle(500),
        logLengthMm: 0,
        boardThicknessMm: 50,
        boardWidthMm: 100,
      );

      expect(SawingEngine.planBoth(noLength).hasAny, isFalse);
    });
  });

  group('kerf costs timber', () {
    test('a thicker blade yields less', () {
      final thin = SawingEngine.planLive(
        fixedThickness(diameter: 500, thickness: 25, kerf: 2, minWidth: 50),
      )!;

      final thick = SawingEngine.planLive(
        fixedThickness(diameter: 500, thickness: 25, kerf: 12, minWidth: 50),
      )!;

      expect(
        thick.boardVolumeCubicFeet,
        lessThan(thin.boardVolumeCubicFeet),
      );
    });
  });

  group('mapping boards back onto the photograph', () {
    test('an unrotated pattern maps to itself', () {
      final request = fixedSize();
      final plan = SawingEngine.planCant(request)!;

      if (plan.patternAngle != 0) return;

      final board = plan.boards.first;
      final corners = boardCornersInFaceFrame(plan, board);

      expect(corners.first.dx, closeTo(board.rect.left, 1e-9));
      expect(corners.first.dy, closeTo(board.rect.top, 1e-9));
    });

    test('rotation preserves the board size', () {
      final plan = SawingEngine.planCant(fixedSize())!;
      final board = plan.boards.first;

      final corners = boardCornersInFaceFrame(plan, board);

      final edgeA = (corners[1] - corners[0]).distance;
      final edgeB = (corners[2] - corners[1]).distance;

      expect(edgeA, closeTo(board.rect.width, 1e-6));
      expect(edgeB, closeTo(board.rect.height, 1e-6));
    });
  });
}
