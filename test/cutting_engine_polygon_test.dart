import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/cutting_models.dart';
import 'package:smartlog2/models/log_defect.dart';
import 'package:smartlog2/models/log_face_outline.dart';
import 'package:smartlog2/services/cutting_engine.dart';

/// An ellipse centred in the first quadrant, like a scaled outline.
LogFaceOutline _oval(double width, double height, {int segments = 72}) {
  return LogFaceOutline([
    for (var i = 0; i < segments; i++)
      Offset(
        width / 2 + (width / 2) * math.cos(2 * math.pi * i / segments),
        height / 2 + (height / 2) * math.sin(2 * math.pi * i / segments),
      ),
  ]);
}

CuttingInput _input({
  required double diameter,
  double boardWidth = 4,
  double boardHeight = 2,
  double blade = 0.125,
}) {
  return CuttingInput(
    logDiameter: diameter,
    logLength: 10,
    boardWidth: boardWidth,
    boardHeight: boardHeight,
    bladeThickness: blade,
    boardPrice: 100,
  );
}

void main() {
  group('shape awareness', () {
    test('an oval log yields more than the circle model allowed', () {
      // A 20in x 14in log. The old engine was handed the *thinnest*
      // diameter and packed into a 14in circle, discarding the rest.
      final asCircle = CuttingEngine.generate(_input(diameter: 14));

      final asOval = CuttingEngine.generate(
        _input(diameter: 14),
        outline: _oval(20, 14),
      );

      expect(asOval.boardCount, greaterThan(asCircle.boardCount));

      // The face really is that much bigger, and the report should say so.
      expect(asOval.logArea, greaterThan(asCircle.logArea * 1.3));
    });

    test('a round log matches the circle model it replaced', () {
      final implicit = CuttingEngine.generate(_input(diameter: 20));

      final explicit = CuttingEngine.generate(
        _input(diameter: 20),
        outline: LogFaceOutline.circle(20),
      );

      // No outline must mean "circle of the measured diameter", not a
      // second, subtly different packing path.
      expect(explicit.boardCount, implicit.boardCount);
    });

    test('every board really is inside the traced face', () {
      final outline = _oval(24, 15);

      final result = CuttingEngine.generate(
        _input(diameter: 15),
        outline: outline,
      );

      expect(result.boardCount, greaterThan(0));

      for (final board in result.boards) {
        expect(
          outline.containsRect(
            Rect.fromLTWH(board.x, board.y, board.width, board.height),
          ),
          isTrue,
          reason: 'board ${board.index} escaped the log',
        );
      }
    });

    test('no board bridges a concave notch', () {
      // A face with a deep bite out of one side, as left by a branch.
      const notched = LogFaceOutline([
        Offset(0, 0),
        Offset(30, 0),
        Offset(30, 30),
        Offset(17, 30),
        Offset(15, 6),
        Offset(13, 30),
        Offset(0, 30),
      ]);

      final result = CuttingEngine.generate(
        _input(diameter: 30, boardWidth: 3, boardHeight: 3),
        outline: notched,
      );

      for (final board in result.boards) {
        expect(
          notched.containsRect(
            Rect.fromLTWH(board.x, board.y, board.width, board.height),
          ),
          isTrue,
          reason: 'board ${board.index} spans the notch',
        );
      }
    });

    test('utilization is measured against the real face area', () {
      final outline = _oval(20, 14);

      final result = CuttingEngine.generate(
        _input(diameter: 14),
        outline: outline,
      );

      expect(result.logArea, closeTo(outline.area, 1e-6));
      expect(result.utilization, lessThanOrEqualTo(100));
      expect(
        result.utilization + result.waste,
        closeTo(100, 1e-9),
      );
    });
  });

  group('rotation search', () {
    test('finds an angle a fixed 0/90 search would have missed', () {
      // A long oval tilted 30 degrees off axis. Packing it upright wastes
      // most of the face; the engine has to find the tilt.
      final tilted = _oval(30, 12).rotated(math.pi / 6);

      final result = CuttingEngine.generate(
        _input(diameter: 12, boardWidth: 5, boardHeight: 2),
        outline: tilted,
      );

      expect(result.boardCount, greaterThan(0));

      // The winning arrangement is not one of the two the old code tried.
      final chosen = result.angle % 90;
      expect(chosen, isNot(closeTo(0, 1e-6)));
    });

    test('reports an angle a sawyer can actually set', () {
      final result = CuttingEngine.generate(
        _input(diameter: 18),
        outline: _oval(18, 18),
      );

      expect(result.angle, greaterThanOrEqualTo(0));
      expect(result.angle, lessThan(180));
    });
  });

  group('defect avoidance', () {
    final outline = _oval(24, 24);

    // A rotten patch dead in the middle of the face.
    final rot = LogDefect(
      kind: LogDefectKind.rot,
      centre: const Offset(12, 12),
      radius: 5,
    );

    test('the toggle is what decides, not the presence of defects', () {
      final ignoring = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
        defects: [rot],
        avoidDefects: false,
      );

      final avoiding = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
        defects: [rot],
        avoidDefects: true,
      );

      expect(avoiding.boardCount, lessThan(ignoring.boardCount));
    });

    test('no board overlaps a defect when avoidance is on', () {
      final result = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
        defects: [rot],
        avoidDefects: true,
      );

      expect(result.boardCount, greaterThan(0));

      for (final board in result.boards) {
        expect(
          rot.overlaps(
            Rect.fromLTWH(board.x, board.y, board.width, board.height),
          ),
          isFalse,
          reason: 'board ${board.index} contains rot',
        );
      }
    });

    test('a mild defect does not delete a board it could only downgrade', () {
      final knot = LogDefect(
        kind: LogDefectKind.knot,
        centre: const Offset(12, 12),
        radius: 5,
      );

      final clean = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
      );

      final withKnot = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
        defects: [knot],
        avoidDefects: true,
      );

      // A knot still yields a sellable, lower-grade board, so it must not
      // silently cost the user the piece.
      expect(knot.isDisqualifying, isFalse);
      expect(withKnot.boardCount, clean.boardCount);
    });

    test('an empty defect list changes nothing', () {
      final withFlag = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
        avoidDefects: true,
      );

      final without = CuttingEngine.generate(
        _input(diameter: 24),
        outline: outline,
      );

      expect(withFlag.boardCount, without.boardCount);
    });
  });

  group('kerf', () {
    test('counts shared cuts once, not once per board', () {
      final result = CuttingEngine.generate(
        _input(diameter: 24, boardWidth: 4, boardHeight: 4, blade: 0.25),
        outline: _oval(24, 24),
      );

      expect(result.boardCount, greaterThan(4));

      // The old formula charged every board a full ring of blade width. An
      // upper bound on the truth is one full ring for a single board; with
      // many boards sharing cuts the total must come in far under the old
      // per-board figure.
      final oldFormula = result.boardCount *
          ((4 + 0.25) * (4 + 0.25) - 16);

      expect(result.kerfLoss, lessThan(oldFormula));
      expect(result.kerfLoss, greaterThan(0));
    });

    test('a log with no blade width wastes no wood to sawdust', () {
      final result = CuttingEngine.generate(
        _input(diameter: 20, blade: 0),
        outline: _oval(20, 20),
      );

      expect(result.kerfLoss, 0);
    });
  });

  group('units', () {
    // The tracing screen works in inches, because that is what a tape reads.
    // Everything from the setup sheet down -- board width, blade kerf, log
    // diameter -- is in millimetres. These pin that boundary: mixing them is
    // silent and expensive, because the engine happily packs any numbers it
    // is given and reports a confident, wrong board count.
    const mmPerInch = 25.4;

    // A 20in log: 62.83in of tape.
    const girthInches = 62.83;

    test('a traced face in mm packs sensibly against mm board sizes', () {
      final tracedInPixels = LogFaceOutline.circle(800);
      final inInches = tracedInPixels.scaledToGirth(girthInches)!;
      final inMillimetres = inInches.scaled(mmPerInch);

      // 508mm across, cut into 150 x 50mm boards with a 3mm blade.
      expect(inMillimetres.equivalentCircleDiameter, closeTo(508, 5));

      final result = CuttingEngine.generate(
        CuttingInput(
          logDiameter: inMillimetres.equivalentCircleDiameter,
          logLength: 3000,
          boardWidth: 150,
          boardHeight: 50,
          bladeThickness: 3,
          boardPrice: 250,
        ),
        outline: inMillimetres,
      );

      // A 20in log genuinely yields a handful of 6x2in boards.
      expect(result.boardCount, greaterThan(3));
      expect(result.boardCount, lessThan(40));
    });

    test('forgetting the conversion yields nothing, never a wrong answer', () {
      // The same log left in inches, handed to millimetre board sizes. A
      // 150mm board cannot fit a 20-unit log, so the engine returns zero
      // rather than a plausible-looking figure someone might invoice against.
      final inInches = LogFaceOutline.circle(800).scaledToGirth(girthInches)!;

      final result = CuttingEngine.generate(
        CuttingInput(
          logDiameter: inInches.equivalentCircleDiameter,
          logLength: 3000,
          boardWidth: 150,
          boardHeight: 50,
          bladeThickness: 3,
          boardPrice: 250,
        ),
        outline: inInches,
      );

      expect(result.boardCount, 0);
    });

    test('defects must ride the same conversion as the outline', () {
      final inInches = LogFaceOutline.circle(800).scaledToGirth(girthInches)!;
      final centreInches = inInches.centroid;

      final defectInches = LogDefect(
        kind: LogDefectKind.rot,
        centre: centreInches,
        radius: 4,
      );

      final outlineMm = inInches.scaled(mmPerInch);
      final defectMm = defectInches.scaled(mmPerInch);

      // Converted together, the defect still sits in the middle of the face.
      expect(outlineMm.contains(defectMm.centre), isTrue);

      // Converted apart, it lands near the corner and blocks the wrong
      // boards -- or none at all.
      expect(outlineMm.contains(defectInches.centre), isFalse);
    });
  });

  group('degenerate input', () {
    test('a board larger than the log yields nothing rather than throwing', () {
      final result = CuttingEngine.generate(
        _input(diameter: 10, boardWidth: 40, boardHeight: 40),
        outline: _oval(10, 10),
      );

      expect(result.boardCount, 0);
      expect(result.utilization, 0);
      expect(result.waste, 100);
    });

    test('an unusable outline falls back rather than producing garbage', () {
      const degenerate = LogFaceOutline([Offset(0, 0), Offset(5, 0)]);

      final result = CuttingEngine.generate(
        _input(diameter: 20),
        outline: degenerate,
      );

      expect(result.boardCount, 0);
      expect(result.boards, isEmpty);
    });
  });
}
