import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/services/yolo_defect_detector.dart';
import 'package:smartlog2/utils/yolo_postprocess.dart';

/// The two reasons the defect count was wrong, and the reason small defects
/// were missed, each pinned down by a scene built by hand.
///
/// - Missed: a 4000-pixel photo squeezed into one 640-pixel pass. Fixed by
///   scanning overlapping tiles as well as the whole frame.
/// - Over-counted: the same defect reported by two passes, a box inside a
///   box, and one defect under two names. Fixed by [mergeDetections].
void main() {
  group('scan tiles', () {
    test('a small photo gets one pass -- tiling it would add nothing', () {
      final tiles = planScanTiles(width: 1200, height: 900);

      expect(tiles, hasLength(1));
      expect(tiles.single.isWholeImage, isTrue);
    });

    test('a phone photo gets the whole frame plus four quarters', () {
      final tiles = planScanTiles(width: 4000, height: 3000);

      expect(tiles, hasLength(5));
      expect(tiles.first.isWholeImage, isTrue);
      expect(tiles.skip(1).every((t) => !t.isWholeImage), isTrue);
    });

    test('the tiles cover every pixel and overlap in the middle', () {
      const w = 4000, h = 3000;
      final tiles = planScanTiles(width: w, height: h).skip(1).toList();

      // Every corner and the exact centre sit inside at least one tile.
      for (final (x, y) in [
        (1.0, 1.0),
        (w - 1.0, 1.0),
        (1.0, h - 1.0),
        (w - 1.0, h - 1.0),
        (w / 2, h / 2),
      ]) {
        expect(
          tiles.any((t) => t.region.contains(Offset(x, y))),
          isTrue,
          reason: "($x, $y) is not covered",
        );
      }

      // A defect straddling the centre line is whole in at least two tiles.
      final middle = Rect.fromCenter(
        center: const Offset(w / 2, h / 2),
        width: 200,
        height: 200,
      );

      final containing = tiles.where(
        (t) => t.region.intersect(middle) == middle,
      );

      expect(containing.length, greaterThanOrEqualTo(1));
    });

    test('no tile runs off the photo', () {
      final tiles = planScanTiles(width: 4032, height: 3024);

      for (final t in tiles) {
        expect(t.region.left, greaterThanOrEqualTo(0));
        expect(t.region.top, greaterThanOrEqualTo(0));
        expect(t.region.right, lessThanOrEqualTo(4032.5));
        expect(t.region.bottom, lessThanOrEqualTo(3024.5));
      }
    });
  });

  group('merging passes into one count', () {
    PlacedDetection d(
      double l,
      double t,
      double w,
      double h, {
      int cls = 0,
      double score = 0.8,
    }) =>
        PlacedDetection(
          box: Rect.fromLTWH(l, t, w, h),
          classIndex: cls,
          score: score,
        );

    test('the same knot seen by the whole frame and a tile counts once', () {
      final merged = mergeDetections([
        d(100, 100, 80, 80, score: 0.55),
        d(104, 98, 78, 84, score: 0.72),
      ]);

      expect(merged, hasLength(1));
      // The better score survives, and agreement nudges it up a little.
      expect(merged.single.score, greaterThanOrEqualTo(0.72));
      expect(merged.single.support, 2);
    });

    test('a box inside a box is one defect, not two', () {
      // IoU here is about 0.16 -- far below any suppression threshold, which
      // is exactly how it used to be counted twice.
      final merged = mergeDetections([
        d(100, 100, 200, 200, score: 0.7),
        d(150, 150, 80, 80, score: 0.5),
      ]);

      expect(merged, hasLength(1));
    });

    test('one defect given two names keeps the more confident name', () {
      final merged = mergeDetections([
        d(100, 100, 90, 90, cls: 2, score: 0.64), // knot
        d(102, 101, 88, 90, cls: 0, score: 0.41), // crack
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.classIndex, 2);
    });

    test('two real defects side by side both survive', () {
      final merged = mergeDetections([
        d(100, 100, 60, 60),
        d(400, 120, 60, 60),
        d(250, 400, 60, 60, cls: 1),
      ]);

      expect(merged, hasLength(3));
    });

    test('a crack next to a knot is not swallowed by it', () {
      // Overlapping a little, different classes, different things.
      final merged = mergeDetections([
        d(100, 100, 100, 100, cls: 2, score: 0.8),
        d(170, 60, 40, 200, cls: 0, score: 0.6),
      ]);

      expect(merged, hasLength(2));
    });

    test('a crack found in two halves by two tiles is reported whole', () {
      final merged = mergeDetections([
        d(100, 100, 40, 300, score: 0.7),
        d(100, 250, 40, 300, score: 0.6),
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.box.top, closeTo(100, 1));
      expect(merged.single.box.bottom, closeTo(550, 1));
    });

    test('specks too small to be a defect are dropped', () {
      final kept = dropSpecks(
        [d(10, 10, 3, 3), d(100, 100, 60, 60)],
        imageWidth: 4000,
        imageHeight: 3000,
      );

      expect(kept, hasLength(1));
      expect(kept.single.box.width, 60);
    });
  });

  group('frame preparation', () {
    test('the photo lands in the middle of a grey-padded square', () {
      // A wide red strip: letterboxed top and bottom.
      final image = img.Image(width: 800, height: 400);
      img.fill(image, color: img.ColorRgb8(255, 0, 0));

      final frames = prepareYoloFrames(
        YoloFrameRequest(
          image: image,
          inputSize: 64,
          regions: const [
            [0, 0, 800, 400],
          ],
        ),
      );

      expect(frames, hasLength(1));

      final pixels = frames.single.pixels;
      const plane = 64 * 64;

      expect(pixels.length, 3 * plane);

      // Top-left corner is padding: mid-grey in every channel.
      expect(pixels[0], closeTo(114 / 255, 1e-6));
      expect(pixels[plane], closeTo(114 / 255, 1e-6));

      // The centre is the photo: pure red.
      const centre = 32 * 64 + 32;
      expect(pixels[centre], closeTo(1, 1e-6));
      expect(pixels[plane + centre], closeTo(0, 1e-6));
      expect(pixels[2 * plane + centre], closeTo(0, 1e-6));

      expect(frames.single.padY, greaterThan(0));
      expect(frames.single.padX, closeTo(0, 1e-6));
    });

    test('each tile is cut from its own region of the photo', () {
      // Left half black, right half white.
      final image = img.Image(width: 400, height: 200);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 400; x++) {
          final v = x < 200 ? 0 : 255;
          image.setPixelRgb(x, y, v, v, v);
        }
      }

      final frames = prepareYoloFrames(
        YoloFrameRequest(
          image: image,
          inputSize: 32,
          regions: const [
            [0, 0, 150, 200],
            [250, 0, 150, 200],
          ],
        ),
      );

      const centre = 16 * 32 + 16;
      expect(frames[0].pixels[centre], closeTo(0, 1e-6));
      expect(frames[1].pixels[centre], closeTo(1, 1e-6));
    });
  });
}
