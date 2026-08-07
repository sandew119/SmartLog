import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/fitted_image_mapper.dart';

void main() {
  group('FittedImageMapper', () {
    // A 1000x500 photo in a 400x400 box: fits to width, bars top and bottom.
    const wide = FittedImageMapper(
      imageSize: Size(1000, 500),
      boxSize: Size(400, 400),
    );

    test('letterboxes a wide photo and centres it', () {
      expect(wide.scale, 0.4);
      expect(wide.displayRect, const Rect.fromLTWH(0, 100, 400, 200));
    });

    test('maps a tap in the middle of the box to the middle of the photo', () {
      final point = wide.toImage(const Offset(200, 200))!;

      expect(point.dx, closeTo(500, 1e-9));
      expect(point.dy, closeTo(250, 1e-9));
    });

    test('rejects a tap on the letterbox bars', () {
      // Above the photo.
      expect(wide.toImage(const Offset(200, 50)), isNull);
      // Below it.
      expect(wide.toImage(const Offset(200, 350)), isNull);
      // Outside the widget entirely.
      expect(wide.toImage(const Offset(-5, 200)), isNull);
    });

    test('round-trips image space through screen space', () {
      const original = Offset(742, 133);

      final screen = wide.toScreen(original);
      final back = wide.toImage(screen)!;

      expect(back.dx, closeTo(original.dx, 1e-9));
      expect(back.dy, closeTo(original.dy, 1e-9));
    });

    test('scales lengths so a defect keeps its size against the log', () {
      expect(wide.lengthToScreen(100), closeTo(40, 1e-9));
    });

    test('letterboxes a tall photo on the sides instead', () {
      const tall = FittedImageMapper(
        imageSize: Size(500, 1000),
        boxSize: Size(400, 400),
      );

      expect(tall.displayRect, const Rect.fromLTWH(100, 0, 200, 400));
      expect(tall.toImage(const Offset(50, 200)), isNull);
      expect(tall.toImage(const Offset(200, 200)), isNotNull);
    });

    test('an unknown image size maps nothing rather than mapping wrongly', () {
      // This is the bug that made the tracing screen unusable: the size was
      // unknown until after a detection, and the detection needed a mapped
      // tap. It must fail visibly, not silently return plausible garbage.
      const unknown = FittedImageMapper(
        imageSize: Size.zero,
        boxSize: Size(400, 400),
      );

      expect(unknown.toImage(const Offset(200, 200)), isNull);
    });

    test('a photo smaller than the box is scaled up, not pinned', () {
      const small = FittedImageMapper(
        imageSize: Size(100, 100),
        boxSize: Size(400, 400),
      );

      expect(small.scale, 4);
      expect(small.displayRect, const Rect.fromLTWH(0, 0, 400, 400));
    });
  });
}
