import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/services/log_face_detector.dart';

/// Paints a pale ellipse on a dark field -- a stand-in for a sawn face
/// against bark and ground.
img.Image _face({
  required int width,
  required int height,
  required double centreX,
  required double centreY,
  required double radiusX,
  required double radiusY,
  int faceLuminance = 210,
  int backgroundLuminance = 40,
  double rotation = 0,
}) {
  final image = img.Image(width: width, height: height);

  final cos = math.cos(-rotation);
  final sin = math.sin(-rotation);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - centreX;
      final dy = y - centreY;

      final rx = dx * cos - dy * sin;
      final ry = dx * sin + dy * cos;

      final inside =
          (rx * rx) / (radiusX * radiusX) + (ry * ry) / (radiusY * radiusY) <=
              1;

      final value = inside ? faceLuminance : backgroundLuminance;
      image.setPixelRgb(x, y, value, value, value);
    }
  }

  return image;
}

void main() {
  group('LogFaceDetector', () {
    test('traces a round face close to its true size', () {
      final image = _face(
        width: 400,
        height: 400,
        centreX: 200,
        centreY: 200,
        radiusX: 120,
        radiusY: 120,
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      expect(detection.isReliable, isTrue);
      expect(detection.confidence, 1.0);

      // Within a couple of percent of the 240px true diameter.
      expect(detection.outline.equivalentCircleDiameter, closeTo(240, 8));
    });

    test('measures an oval as oval, which is the whole point', () {
      // 300 x 160 px: exactly the log the circle model handles worst.
      final image = _face(
        width: 500,
        height: 400,
        centreX: 250,
        centreY: 200,
        radiusX: 150,
        radiusY: 80,
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(250, 200),
      )!;

      final axes = detection.outline.axes;

      expect(axes.major, closeTo(300, 12));
      expect(axes.minor, closeTo(160, 12));

      // The old engine would have packed into a circle of the *thinnest*
      // width and thrown away everything past it.
      final circleArea = math.pi * 80 * 80;
      expect(detection.outline.area, greaterThan(circleArea * 1.5));
    });

    test('finds the face when the tap is off-centre', () {
      final image = _face(
        width: 400,
        height: 400,
        centreX: 200,
        centreY: 200,
        radiusX: 120,
        radiusY: 120,
      );

      // A real fingertip lands somewhere in the middle-ish, not dead centre.
      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(235, 175),
      )!;

      // Area is the robust measure here: rays from an off-centre origin
      // still land on the same boundary.
      expect(detection.outline.area, closeTo(math.pi * 120 * 120, 6000));
    });

    test('reports low confidence when the face barely stands out', () {
      // Sawn face on pale sawdust -- almost no edge to find.
      final image = _face(
        width: 400,
        height: 400,
        centreX: 200,
        centreY: 200,
        radiusX: 120,
        radiusY: 120,
        faceLuminance: 150,
        backgroundLuminance: 146,
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      // Must not quietly hand back a confident-looking wrong outline.
      expect(detection.isReliable, isFalse);
      expect(detection.weakRays, greaterThan(0));
    });

    test('a single bright intrusion does not spike the outline', () {
      final image = _face(
        width: 400,
        height: 400,
        centreX: 200,
        centreY: 200,
        radiusX: 120,
        radiusY: 120,
      );

      // A glare streak running off the face to the frame edge, of the kind
      // sunlight on a wet log produces.
      for (var x = 200; x < 400; x++) {
        for (var y = 196; y < 204; y++) {
          image.setPixelRgb(x, y, 240, 240, 240);
        }
      }

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      // Without the median filter the rays along the streak would run to the
      // frame edge and blow the area out.
      expect(detection.outline.area, lessThan(math.pi * 140 * 140));
    });

    test('detection is independent of photo resolution', () {
      // The same log, shot on two different phones.
      final small = LogFaceDetector.detect(
        image: _face(
          width: 300,
          height: 300,
          centreX: 150,
          centreY: 150,
          radiusX: 90,
          radiusY: 90,
        ),
        centre: const Offset(150, 150),
      )!;

      final large = LogFaceDetector.detect(
        image: _face(
          width: 1200,
          height: 1200,
          centreX: 600,
          centreY: 600,
          radiusX: 360,
          radiusY: 360,
        ),
        centre: const Offset(600, 600),
      )!;

      // Outlines come back in their own image's pixels, so compare shape:
      // both are circles of the same proportion of the frame.
      final smallRatio = small.outline.equivalentCircleDiameter / 300;
      final largeRatio = large.outline.equivalentCircleDiameter / 1200;

      expect(smallRatio, closeTo(largeRatio, 0.02));
    });

    test('refuses nonsense input rather than guessing', () {
      final image = _face(
        width: 400,
        height: 400,
        centreX: 200,
        centreY: 200,
        radiusX: 120,
        radiusY: 120,
      );

      // Tap outside the photo.
      expect(
        LogFaceDetector.detect(
          image: image,
          centre: const Offset(-10, 200),
        ),
        isNull,
      );

      // Too few rays to make a shape worth packing into.
      expect(
        LogFaceDetector.detect(
          image: image,
          centre: const Offset(200, 200),
          rayCount: 4,
        ),
        isNull,
      );

      // A thumbnail carries no usable boundary.
      expect(
        LogFaceDetector.detect(
          image: img.Image(width: 8, height: 8),
          centre: const Offset(4, 4),
        ),
        isNull,
      );
    });

    test('scales to inches off the girth, end to end', () {
      // A 20in log measures 62.83in around.
      final image = _face(
        width: 600,
        height: 600,
        centreX: 300,
        centreY: 300,
        radiusX: 200,
        radiusY: 200,
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(300, 300),
      )!;

      final inches = detection.outline.scaledToGirth(62.83)!;

      expect(inches.equivalentCircleDiameter, closeTo(20, 0.5));
      expect(inches.perimeter, closeTo(62.83, 1e-6));
    });
  });
}
