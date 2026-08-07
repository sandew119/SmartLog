import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_face_outline.dart';

void main() {
  group('LogFaceOutline geometry', () {
    test('a square has the area and perimeter it should', () {
      const square = LogFaceOutline([
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 10),
        Offset(0, 10),
      ]);

      expect(square.area, 100);
      expect(square.perimeter, 40);
      expect(square.centroid.dx, closeTo(5, 1e-9));
      expect(square.centroid.dy, closeTo(5, 1e-9));
    });

    test('area is positive whichever way the points were collected', () {
      const clockwise = LogFaceOutline([
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 10),
        Offset(0, 10),
      ]);

      const anticlockwise = LogFaceOutline([
        Offset(0, 10),
        Offset(10, 10),
        Offset(10, 0),
        Offset(0, 0),
      ]);

      // Winding direction is an accident of tracing order and must never
      // flip the sign of a yield figure.
      expect(clockwise.area, anticlockwise.area);
      expect(anticlockwise.area, greaterThan(0));
    });

    test('a generated circle approximates pi r squared', () {
      final circle = LogFaceOutline.circle(20);

      // A 72-gon slightly under-runs the true circle, hence the tolerance.
      expect(circle.area, closeTo(math.pi * 100, 1));
      expect(circle.perimeter, closeTo(2 * math.pi * 10, 0.5));
      expect(circle.equivalentCircleDiameter, closeTo(20, 0.1));
    });

    test('degenerate outlines report zero rather than throwing', () {
      const line = LogFaceOutline([Offset(0, 0), Offset(10, 0)]);
      const empty = LogFaceOutline([]);

      expect(line.isValid, isFalse);
      expect(line.area, 0);
      expect(empty.area, 0);
      expect(empty.bounds, Rect.zero);
      expect(empty.contains(Offset.zero), isFalse);
    });
  });

  group('containment', () {
    final circle = LogFaceOutline.circle(20);

    test('knows inside from outside', () {
      expect(circle.contains(const Offset(10, 10)), isTrue);
      expect(circle.contains(const Offset(0.5, 0.5)), isFalse);
      expect(circle.contains(const Offset(50, 50)), isFalse);
    });

    test('accepts a rectangle that fits and rejects one that does not', () {
      expect(circle.containsRect(const Rect.fromLTWH(5, 5, 10, 10)), isTrue);
      expect(circle.containsRect(const Rect.fromLTWH(0, 0, 20, 20)), isFalse);
    });

    test('rejects a board that bridges a concave notch', () {
      // A square with a deep V bitten out of the top edge -- the dent left
      // where a branch came off.
      const notched = LogFaceOutline([
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(55, 100),
        Offset(50, 20), // the notch, cutting almost to the far edge
        Offset(45, 100),
        Offset(0, 100),
      ]);

      // All four corners of this board sit in solid wood, but its middle
      // spans the notch. Testing corners alone would wrongly accept it.
      const bridging = Rect.fromLTWH(30, 80, 40, 15);

      for (final corner in [
        bridging.topLeft,
        bridging.topRight,
        bridging.bottomLeft,
        bridging.bottomRight,
      ]) {
        expect(
          notched.contains(corner),
          isTrue,
          reason: 'corner $corner should be inside',
        );
      }

      expect(notched.containsRect(bridging), isFalse);
    });
  });

  group('axes', () {
    test('a circle measures the same every way through', () {
      final axes = LogFaceOutline.circle(30).axes;

      expect(axes.major, closeTo(30, 0.5));
      expect(axes.minor, closeTo(30, 0.5));
    });

    test('an oval reports its long and short widths', () {
      // 40 wide, 20 tall -- the exact case the circle model handles worst.
      final oval = LogFaceOutline([
        for (var i = 0; i < 72; i++)
          Offset(
            20 * math.cos(2 * math.pi * i / 72),
            10 * math.sin(2 * math.pi * i / 72),
          ),
      ]);

      expect(oval.axes.major, closeTo(40, 0.5));
      expect(oval.axes.minor, closeTo(20, 0.5));
    });
  });

  group('scaledToGirth', () {
    test('turns a pixel outline into inches using the tape reading', () {
      // A circle 200px around, measured at 62.83in of tape (a 20in log).
      final pixels = LogFaceOutline.circle(200);
      final scaled = pixels.scaledToGirth(62.83)!;

      // Perimeter must come back as exactly the girth that was measured --
      // that is the whole basis of the calibration.
      expect(scaled.perimeter, closeTo(62.83, 1e-6));
      expect(scaled.equivalentCircleDiameter, closeTo(20, 0.1));
    });

    test('scale is independent of how far away the photo was taken', () {
      // The same log shot from twice the distance is half the pixels.
      final near = LogFaceOutline.circle(400).scaledToGirth(62.83)!;
      final far = LogFaceOutline.circle(200).scaledToGirth(62.83)!;

      expect(
        near.equivalentCircleDiameter,
        closeTo(far.equivalentCircleDiameter, 1e-6),
      );
    });

    test('normalises to the origin so packing works in one quadrant', () {
      final offset = LogFaceOutline.circle(200).translated(
        const Offset(500, 300),
      );

      final scaled = offset.scaledToGirth(62.83)!;

      expect(scaled.bounds.left, closeTo(0, 1e-9));
      expect(scaled.bounds.top, closeTo(0, 1e-9));
    });

    test('refuses to scale from nothing instead of inventing a size', () {
      expect(LogFaceOutline.circle(200).scaledToGirth(0), isNull);
      expect(LogFaceOutline.circle(200).scaledToGirth(-5), isNull);
      expect(const LogFaceOutline([]).scaledToGirth(60), isNull);
    });
  });

  group('transforms', () {
    test('rotation preserves area and perimeter', () {
      final oval = LogFaceOutline([
        for (var i = 0; i < 72; i++)
          Offset(
            20 * math.cos(2 * math.pi * i / 72),
            10 * math.sin(2 * math.pi * i / 72),
          ),
      ]);

      final turned = oval.rotated(math.pi / 5);

      expect(turned.area, closeTo(oval.area, 1e-6));
      expect(turned.perimeter, closeTo(oval.perimeter, 1e-6));
    });

    test('a quarter turn swaps the bounding box of an oval', () {
      final oval = LogFaceOutline([
        for (var i = 0; i < 72; i++)
          Offset(
            20 * math.cos(2 * math.pi * i / 72),
            10 * math.sin(2 * math.pi * i / 72),
          ),
      ]);

      final turned = oval.rotated(math.pi / 2);

      expect(turned.bounds.width, closeTo(oval.bounds.height, 1e-6));
      expect(turned.bounds.height, closeTo(oval.bounds.width, 1e-6));
    });
  });
}
