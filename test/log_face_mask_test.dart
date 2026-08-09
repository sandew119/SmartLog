import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_face_outline.dart';
import 'package:smartlog2/utils/log_face_mask.dart';

LogFaceOutline ellipseOutline({
  required double a,
  required double b,
  Offset centre = const Offset(0, 0),
  int segments = 144,
}) {
  return LogFaceOutline(
    List.generate(segments, (i) {
      final t = 2 * math.pi * i / segments;
      return Offset(centre.dx + a * math.cos(t), centre.dy + b * math.sin(t));
    }),
  );
}

/// A circle with a deep notch cut into its right side -- the dent left where
/// a branch came off. Boards must not bridge over it.
LogFaceOutline notchedCircle({double radius = 100, int segments = 144}) {
  return LogFaceOutline(
    List.generate(segments, (i) {
      final t = 2 * math.pi * i / segments;
      final degrees = t * 180 / math.pi;

      // Pull the boundary sharply inward over a narrow wedge on the right.
      final r = (degrees > 345 || degrees < 15) ? radius * 0.45 : radius;

      return Offset(radius + r * math.cos(t), radius + r * math.sin(t));
    }),
  );
}

void main() {
  group('construction', () {
    test('builds from a circle and reports a plausible usable area', () {
      final outline = LogFaceOutline.circle(200);
      final mask = LogFaceMask.fromOutline(outline)!;

      final trueArea = math.pi * 100 * 100;

      // Erosion makes the mask deliberately smaller than the real face.
      expect(mask.usableArea, lessThan(trueArea));
      expect(mask.usableArea, greaterThan(trueArea * 0.95));
    });

    test('refuses degenerate input rather than returning an empty mask', () {
      expect(LogFaceMask.fromOutline(const LogFaceOutline([])), isNull);
      expect(
        LogFaceMask.fromOutline(
          const LogFaceOutline([Offset(0, 0), Offset(1, 0), Offset(2, 0)]),
        ),
        isNull,
      );
    });
  });

  group('containsRect agrees with the polygon', () {
    test('accepts rectangles well inside a circle', () {
      final outline = LogFaceOutline.circle(200);
      final mask = LogFaceMask.fromOutline(outline)!;

      // Centred square of side 100 sits comfortably inside a 200 circle.
      expect(mask.containsRect(const Rect.fromLTWH(50, 50, 100, 100)), isTrue);
    });

    test('rejects rectangles that poke outside', () {
      final outline = LogFaceOutline.circle(200);
      final mask = LogFaceMask.fromOutline(outline)!;

      expect(mask.containsRect(const Rect.fromLTWH(0, 0, 200, 200)), isFalse);
      expect(mask.containsRect(const Rect.fromLTWH(-20, 90, 40, 20)), isFalse);
      expect(mask.containsRect(const Rect.fromLTWH(180, 90, 40, 20)), isFalse);
    });

    test(
        'never claims a rectangle fits when the polygon says it does not -- '
        'the mask is allowed to be pessimistic, never optimistic', () {
      final outline = LogFaceOutline.circle(200);
      final mask = LogFaceMask.fromOutline(outline)!;

      final random = math.Random(11);
      var checked = 0;

      for (var i = 0; i < 400; i++) {
        final rect = Rect.fromLTWH(
          random.nextDouble() * 220 - 10,
          random.nextDouble() * 220 - 10,
          random.nextDouble() * 120 + 4,
          random.nextDouble() * 120 + 4,
        );

        if (mask.containsRect(rect)) {
          checked++;
          expect(
            outline.containsRect(rect, samplesPerEdge: 8),
            isTrue,
            reason: "mask accepted $rect but the polygon rejects it",
          );
        }
      }

      // Guard against the assertion above passing vacuously.
      expect(checked, greaterThan(20));
    });

    test('holds for an ellipse too, not just a circle', () {
      final outline =
          ellipseOutline(a: 120, b: 60, centre: const Offset(130, 70));
      final mask = LogFaceMask.fromOutline(outline)!;

      final random = math.Random(5);
      var accepted = 0;

      for (var i = 0; i < 400; i++) {
        final rect = Rect.fromLTWH(
          random.nextDouble() * 260,
          random.nextDouble() * 140,
          random.nextDouble() * 100 + 4,
          random.nextDouble() * 60 + 4,
        );

        if (mask.containsRect(rect)) {
          accepted++;
          expect(outline.containsRect(rect, samplesPerEdge: 8), isTrue);
        }
      }

      expect(accepted, greaterThan(20));
    });

    test('a board cannot bridge over a notch', () {
      final outline = notchedCircle();
      final mask = LogFaceMask.fromOutline(outline)!;

      // A wide board across the middle would span straight over the wedge
      // taken out of the right-hand side.
      expect(
        mask.containsRect(const Rect.fromLTWH(30, 90, 160, 20)),
        isFalse,
      );

      // The same board kept clear of the notch is fine.
      expect(
        mask.containsRect(const Rect.fromLTWH(30, 90, 80, 20)),
        isTrue,
      );
    });

    test('degenerate rectangles are rejected, not crashed on', () {
      final mask = LogFaceMask.fromOutline(LogFaceOutline.circle(200))!;

      expect(mask.containsRect(const Rect.fromLTWH(100, 100, 0, 10)), isFalse);
      expect(mask.containsRect(const Rect.fromLTWH(100, 100, 10, 0)), isFalse);
      expect(
        mask.containsRect(const Rect.fromLTWH(100, 100, -10, -10)),
        isFalse,
      );
      expect(
        mask.containsRect(Rect.fromLTWH(double.nan, 0, 10, 10)),
        isFalse,
      );
    });
  });

  group('widestRunInBand', () {
    test('matches the chord width of a circle', () {
      final outline = LogFaceOutline.circle(200);
      final mask = LogFaceMask.fromOutline(outline)!;

      // Band straddling the centre: the limiting width is the chord at the
      // band edge furthest from the centre.
      const top = 90.0;
      const bottom = 110.0;

      final run = mask.widestRunInBand(top, bottom)!;

      final dy = math.max((top - 100).abs(), (bottom - 100).abs());
      final expected = 2 * math.sqrt(100 * 100 - dy * dy);

      expect(run.right - run.left, closeTo(expected, mask.cellSize * 3));
    });

    test('narrows towards the top of the log, as a circle must', () {
      final mask = LogFaceMask.fromOutline(LogFaceOutline.circle(200))!;

      final middle = mask.widestRunInBand(95, 105)!;
      final upper = mask.widestRunInBand(20, 30)!;

      expect(middle.right - middle.left, greaterThan(upper.right - upper.left));
    });

    test('returns null for a band entirely outside the log', () {
      final mask = LogFaceMask.fromOutline(LogFaceOutline.circle(200))!;

      expect(mask.widestRunInBand(-50, -40), isNull);
      expect(mask.widestRunInBand(300, 320), isNull);
      expect(mask.widestRunInBand(100, 90), isNull);
    });

    test('reports only the widest continuous run, not the total usable width',
        () {
      // An hourglass pinched to nothing in the middle of the band: the two
      // lobes must not be reported as one wide board.
      final outline = LogFaceOutline([
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 40),
        const Offset(55, 50),
        const Offset(100, 60),
        const Offset(100, 100),
        const Offset(0, 100),
        const Offset(0, 60),
        const Offset(45, 50),
        const Offset(0, 40),
      ]);

      final mask = LogFaceMask.fromOutline(outline)!;
      final run = mask.widestRunInBand(48, 52);

      // Whatever it finds, it must be one side only -- never the full span.
      if (run != null) {
        expect(run.right - run.left, lessThan(60));
      }
    });
  });

  group('widestRectOfHeight', () {
    test('finds the widest slab of a given thickness in a circle', () {
      final mask = LogFaceMask.fromOutline(LogFaceOutline.circle(200))!;

      final rect = mask.widestRectOfHeight(20)!;

      // The widest 20-thick band in a 200 circle straddles the centre.
      final expected = 2 * math.sqrt(100 * 100 - 10 * 10);

      expect(rect.width, closeTo(expected, mask.cellSize * 4));
      expect(rect.height, closeTo(20, 1e-9));
      expect(rect.center.dy, closeTo(100, mask.cellSize * 4));
    });

    test('returns null when nothing that thick fits', () {
      final mask = LogFaceMask.fromOutline(LogFaceOutline.circle(200))!;

      expect(mask.widestRectOfHeight(400), isNull);
      expect(mask.widestRectOfHeight(0), isNull);
    });

    test('a thicker slab is never wider than a thinner one', () {
      final mask = LogFaceMask.fromOutline(LogFaceOutline.circle(200))!;

      final thin = mask.widestRectOfHeight(10)!;
      final thick = mask.widestRectOfHeight(80)!;

      expect(thick.width, lessThan(thin.width));
    });
  });
}
