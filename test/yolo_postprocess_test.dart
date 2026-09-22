import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/yolo_postprocess.dart';

/// The arithmetic behind [YoloDefectDetector], checked against scenes built
/// by hand rather than the real model -- there is no phone to run it on
/// from here, and no metadata in the exported file to confirm its
/// conventions against. What is checked here is that the *decoder* does
/// what the standard YOLO export contract says it should; whether that
/// contract actually matches this particular file is a question only a
/// labelled photo on a real device can answer.
void main() {
  group('Letterbox', () {
    test('a square photo needs no padding', () {
      final box = Letterbox.fit(
        inputSize: 640,
        originalWidth: 1000,
        originalHeight: 1000,
      );

      expect(box.scale, closeTo(0.64, 1e-9));
      expect(box.padX, closeTo(0, 1e-9));
      expect(box.padY, closeTo(0, 1e-9));
    });

    test('a portrait photo is padded left and right', () {
      // 3000x4000: taller than wide, so it is scaled to fill the height and
      // padded on the sides.
      final box = Letterbox.fit(
        inputSize: 640,
        originalWidth: 3000,
        originalHeight: 4000,
      );

      expect(box.scale, closeTo(640 / 4000, 1e-9));
      expect(box.resizedWidth, closeTo(3000 * 640 / 4000, 1));
      expect(box.resizedHeight, 640);
      expect(box.padY, closeTo(0, 1e-9));
      expect(box.padX, greaterThan(0));
    });

    test('a landscape photo is padded top and bottom', () {
      final box = Letterbox.fit(
        inputSize: 640,
        originalWidth: 4000,
        originalHeight: 2250,
      );

      expect(box.scale, closeTo(640 / 4000, 1e-9));
      expect(box.padX, closeTo(0, 1e-9));
      expect(box.padY, greaterThan(0));
    });

    test('a box in the model square maps back onto the real photo', () {
      const originalW = 4000, originalH = 2250;
      final box = Letterbox.fit(
        inputSize: 640,
        originalWidth: originalW,
        originalHeight: originalH,
      );

      // Dead centre of the model square should land dead centre of the photo.
      final centre = box.toOriginal(
        Rect.fromCenter(center: const Offset(320, 320), width: 40, height: 40),
      );

      expect(centre.center.dx, closeTo(originalW / 2, 2));
      expect(centre.center.dy, closeTo(originalH / 2, 2));

      // A box the full width of the resized image, at zero height offset --
      // the very top edge inside the padding -- should map to the top of
      // the photo and span its full width.
      final full = box.toOriginal(
        Rect.fromLTWH(box.padX, box.padY, box.resizedWidth.toDouble(), 10),
      );

      expect(full.left, closeTo(0, 2));
      expect(full.right, closeTo(originalW.toDouble(), 2));
      expect(full.top, closeTo(0, 2));
    });

    test('a box is never reported outside the real photo', () {
      final box = Letterbox.fit(
        inputSize: 640,
        originalWidth: 3000,
        originalHeight: 4000,
      );

      // Entirely inside the padding strip -- off the real photo altogether.
      final offEdge = box.toOriginal(
        Rect.fromLTWH(0, 0, 20, 20),
      );

      expect(offEdge.left, greaterThanOrEqualTo(0));
      expect(offEdge.top, greaterThanOrEqualTo(0));
      expect(offEdge.right, lessThanOrEqualTo(3000));
      expect(offEdge.bottom, lessThanOrEqualTo(4000));
    });

    test('a degenerate photo size does not divide by zero', () {
      final box = Letterbox.fit(inputSize: 640, originalWidth: 0, originalHeight: 0);
      expect(box.scale.isFinite, isTrue);
      expect(() => box.toOriginal(const Rect.fromLTWH(0, 0, 10, 10)), returnsNormally);
    });
  });

  group('decodeYoloDetectionHead', () {
    /// Builds a `[4 + numClasses][numAnchors]` raw tensor with all-zero
    /// scores, then plants detections at chosen anchor indices.
    List<List<double>> emptyRaw(int numClasses, int numAnchors) => [
          for (var i = 0; i < 4 + numClasses; i++) List<double>.filled(numAnchors, 0),
        ];

    void plant(
      List<List<double>> raw,
      int anchor, {
      required double cx,
      required double cy,
      required double w,
      required double h,
      required int classIndex,
      required double score,
    }) {
      raw[0][anchor] = cx;
      raw[1][anchor] = cy;
      raw[2][anchor] = w;
      raw[3][anchor] = h;
      raw[4 + classIndex][anchor] = score;
    }

    test('finds a single planted detection above threshold', () {
      final raw = emptyRaw(3, 100);
      plant(raw, 42, cx: 300, cy: 200, w: 50, h: 60, classIndex: 0, score: 0.8);

      final found = decodeYoloDetectionHead(raw, numClasses: 3, scoreThreshold: 0.25);

      expect(found.length, 1);
      expect(found.first.classIndex, 0);
      expect(found.first.score, closeTo(0.8, 1e-9));
      expect(found.first.cx, 300);
      expect(found.first.boxInModelSpace, const Rect.fromLTWH(275, 170, 50, 60));
    });

    test('ignores anchors below the threshold', () {
      final raw = emptyRaw(3, 10);
      plant(raw, 3, cx: 1, cy: 1, w: 1, h: 1, classIndex: 1, score: 0.1);

      final found = decodeYoloDetectionHead(raw, numClasses: 3, scoreThreshold: 0.25);
      expect(found, isEmpty);
    });

    test('picks the highest-scoring class at one anchor', () {
      final raw = emptyRaw(3, 5);
      raw[0][2] = 10;
      raw[1][2] = 10;
      raw[2][2] = 5;
      raw[3][2] = 5;
      raw[4][2] = 0.3; // Crack
      raw[5][2] = 0.9; // Hole
      raw[6][2] = 0.4; // Knot

      final found = decodeYoloDetectionHead(raw, numClasses: 3, scoreThreshold: 0.25);

      expect(found.length, 1);
      expect(found.first.classIndex, 1);
      expect(found.first.score, closeTo(0.9, 1e-9));
    });

    test('applies a sigmoid automatically when scores look like logits', () {
      final raw = emptyRaw(3, 5);
      plant(raw, 0, cx: 1, cy: 1, w: 1, h: 1, classIndex: 0, score: 4.0); // logit
      plant(raw, 1, cx: 1, cy: 1, w: 1, h: 1, classIndex: 1, score: 6.0); // pushes peak > 1.5

      final found = decodeYoloDetectionHead(raw, numClasses: 3, scoreThreshold: 0.25);

      // sigmoid(4.0) ~ 0.982, sigmoid(6.0) ~ 0.9975
      expect(found.any((d) => (d.score - sigmoid(4.0)).abs() < 1e-6), isTrue);
      expect(found.any((d) => (d.score - sigmoid(6.0)).abs() < 1e-6), isTrue);
    });

    test('trusts scores already in 0..1 and leaves them alone', () {
      final raw = emptyRaw(3, 5);
      plant(raw, 0, cx: 1, cy: 1, w: 1, h: 1, classIndex: 0, score: 0.77);

      final found = decodeYoloDetectionHead(raw, numClasses: 3, scoreThreshold: 0.25);

      expect(found.single.score, closeTo(0.77, 1e-9));
    });

    test('an output too short for the declared class count is refused, not crashed on', () {
      final raw = [List<double>.filled(5, 0), List<double>.filled(5, 0)]; // only 2 rows
      expect(decodeYoloDetectionHead(raw, numClasses: 3), isEmpty);
    });
  });

  group('nonMaxSuppression', () {
    RawDetection box(double cx, double cy, double w, double h, int cls, double score) =>
        RawDetection(cx: cx, cy: cy, w: w, h: h, classIndex: cls, score: score);

    test('the highest-scoring of two heavily overlapping same-class boxes wins', () {
      final kept = nonMaxSuppression([
        box(100, 100, 40, 40, 0, 0.6),
        box(102, 101, 40, 40, 0, 0.9), // near-identical box, higher score
      ]);

      expect(kept.length, 1);
      expect(kept.single.score, closeTo(0.9, 1e-9));
    });

    test('two different classes at the same place both survive', () {
      final kept = nonMaxSuppression([
        box(100, 100, 40, 40, 0, 0.6),
        box(100, 100, 40, 40, 1, 0.9),
      ]);

      expect(kept.length, 2);
    });

    test('two boxes far apart both survive', () {
      final kept = nonMaxSuppression([
        box(50, 50, 20, 20, 0, 0.7),
        box(500, 500, 20, 20, 0, 0.8),
      ]);

      expect(kept.length, 2);
    });

    test('a chain of overlapping boxes collapses to the one best box', () {
      // A crack drawn across several anchors typically fires several
      // adjacent, heavily overlapping boxes -- exactly the case NMS exists
      // for, and the case an off-by-one in the loop would leave doubled.
      final kept = nonMaxSuppression([
        box(100, 100, 60, 20, 0, 0.5),
        box(105, 100, 60, 20, 0, 0.6),
        box(110, 100, 60, 20, 0, 0.95),
        box(115, 100, 60, 20, 0, 0.55),
      ]);

      expect(kept.length, 1);
      expect(kept.single.score, closeTo(0.95, 1e-9));
    });

    test('caps the number of findings on a very noisy frame', () {
      final many = [
        for (var i = 0; i < 200; i++) box(i * 1000.0, i * 1000.0, 5, 5, 0, 0.3 + i * 0.001),
      ];

      final kept = nonMaxSuppression(many, maxPerImage: 50);
      expect(kept.length, 50);
      // The kept set is the highest scoring, not an arbitrary prefix.
      expect(kept.first.score, greaterThanOrEqualTo(kept.last.score));
    });

    test('an empty frame produces no findings', () {
      expect(nonMaxSuppression(const []), isEmpty);
    });
  });

  group('end to end: a decode, then suppression, on a synthetic frame', () {
    test('a crack, a knot and a duplicate crack box collapse to two findings', () {
      const numClasses = 3, numAnchors = 50;
      final raw = [for (var i = 0; i < 4 + numClasses; i++) List<double>.filled(numAnchors, 0)];

      void plant(int a, double cx, double cy, double w, double h, int cls, double score) {
        raw[0][a] = cx;
        raw[1][a] = cy;
        raw[2][a] = w;
        raw[3][a] = h;
        raw[4 + cls][a] = score;
      }

      plant(5, 200, 200, 80, 30, 0, 0.7); // Crack
      plant(6, 205, 202, 80, 30, 0, 0.9); // same crack, another anchor, wins
      plant(20, 400, 400, 50, 50, 2, 0.85); // Knot, well away from the crack

      final decoded = decodeYoloDetectionHead(raw, numClasses: numClasses, scoreThreshold: 0.25);
      final kept = nonMaxSuppression(decoded);

      expect(kept.length, 2);

      final crack = kept.firstWhere((d) => d.classIndex == 0);
      final knot = kept.firstWhere((d) => d.classIndex == 2);

      expect(crack.score, closeTo(0.9, 1e-9));
      expect(knot.score, closeTo(0.85, 1e-9));

      // And the coordinates survive the round trip through a letterbox onto
      // a real (non-square) photo size.
      final letterbox = Letterbox.fit(inputSize: 640, originalWidth: 3000, originalHeight: 4000);
      final crackOnPhoto = letterbox.toOriginal(crack.boxInModelSpace);

      expect(crackOnPhoto.left, greaterThanOrEqualTo(0));
      expect(crackOnPhoto.right, lessThanOrEqualTo(3000));
    });
  });

  test('sigmoid is a real sigmoid', () {
    expect(sigmoid(0), closeTo(0.5, 1e-9));
    expect(sigmoid(100), closeTo(1.0, 1e-6));
    expect(sigmoid(-100), closeTo(0.0, 1e-6));
    expect(sigmoid(1), closeTo(1 / (1 + math.exp(-1)), 1e-12));
  });
}
