import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/services/log_face_detector.dart';

/// Paints a log face onto a background.
///
/// Generating the picture here is what makes the detector testable at all on
/// a machine with no camera: the true centre and radii are known exactly, so
/// the assertions can be about accuracy rather than "it returned something".
img.Image syntheticFace({
  int width = 400,
  int height = 400,
  required Offset centre,
  required double radiusX,
  required double radiusY,
  required List<int> faceRgb,
  required List<int> backgroundRgb,
  double rotation = 0,
  double noise = 0,
  int seed = 5,
}) {
  final image = img.Image(width: width, height: height);
  final random = math.Random(seed);

  final cos = math.cos(-rotation);
  final sin = math.sin(-rotation);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - centre.dx;
      final dy = y - centre.dy;

      final u = dx * cos - dy * sin;
      final v = dx * sin + dy * cos;

      final inside =
          (u * u) / (radiusX * radiusX) + (v * v) / (radiusY * radiusY) <= 1;

      final base = inside ? faceRgb : backgroundRgb;

      int jitter(int channel) {
        if (noise <= 0) return channel;
        final n = ((random.nextDouble() - 0.5) * 2 * noise).round();
        return (channel + n).clamp(0, 255);
      }

      image.setPixelRgb(
          x, y, jitter(base[0]), jitter(base[1]), jitter(base[2]));
    }
  }

  return image;
}

void main() {
  group('the case the old detector got wrong', () {
    test('a DARK face on a LIGHT background is found', () {
      // Weathered grey log end on pale sawdust. The previous detector
      // assumed the face was the brighter thing and would walk straight
      // past this boundary.
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 120,
        radiusY: 120,
        faceRgb: const [70, 65, 60],
        backgroundRgb: const [215, 210, 200],
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(120, 12));
      expect(detection.ellipse.semiMinor, closeTo(120, 12));
      expect(
        (detection.ellipse.centre - const Offset(200, 200)).distance,
        lessThan(12),
      );
      expect(detection.isReliable, isTrue);
    });

    test('a LIGHT face on a DARK background is found just as well', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 120,
        radiusY: 120,
        faceRgb: const [220, 200, 165],
        backgroundRgb: const [45, 40, 35],
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(120, 12));
      expect(detection.isReliable, isTrue);
    });

    test('a face separated only by COLOUR, not brightness, is found', () {
      // Same luminance, different hue -- a purely brightness-based edge
      // detector sees nothing at all here.
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 110,
        radiusY: 110,
        faceRgb: const [180, 140, 90],
        backgroundRgb: const [90, 150, 175],
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(110, 14));
    });
  });

  group('shape', () {
    test('recovers an elliptical face -- a round end seen at an angle', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 150,
        radiusY: 90,
        faceRgb: const [210, 190, 155],
        backgroundRgb: const [40, 38, 35],
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(150, 15));
      expect(detection.ellipse.semiMinor, closeTo(90, 15));

      // The major axis is the true diameter; the minor is foreshortened.
      expect(detection.ellipse.trueDiameter, closeTo(300, 30));
    });

    test('recovers a rotated ellipse', () {
      final image = syntheticFace(
        width: 460,
        height: 460,
        centre: const Offset(230, 230),
        radiusX: 150,
        radiusY: 85,
        rotation: 40 * math.pi / 180,
        faceRgb: const [205, 185, 150],
        backgroundRgb: const [35, 33, 30],
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(230, 230),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(150, 18));
      expect(detection.ellipse.semiMinor, closeTo(85, 18));
    });

    test('the outline it returns is usable by the packing engine', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 120,
        radiusY: 120,
        faceRgb: const [215, 195, 160],
        backgroundRgb: const [40, 38, 35],
      );

      final outline = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!
          .outline;

      expect(outline.isValid, isTrue);
      expect(outline.points.length, 72);
      expect(outline.equivalentCircleDiameter, closeTo(240, 25));

      // No spikes: every radius close to the mean.
      final centre = outline.centroid;
      final radii = [for (final p in outline.points) (p - centre).distance];
      final mean = radii.reduce((a, b) => a + b) / radii.length;

      for (final r in radii) {
        expect(r, closeTo(mean, mean * 0.3));
      }
    });
  });

  group('bark — the edge that was being missed', () {
    /// A sawn face with a bark ring around it, which is what a real log
    /// looks like: pale sawn timber, then a dark band of bark, then ground.
    img.Image barkedFace({
      required double woodRadius,
      required double barkRadius,
    }) {
      final image = syntheticFace(
        width: 460,
        height: 460,
        centre: const Offset(230, 230),
        radiusX: barkRadius,
        radiusY: barkRadius,
        // Bark: dark brown, and much closer to the ground colour than to
        // the sawn face.
        faceRgb: const [62, 48, 38],
        backgroundRgb: const [120, 125, 110],
      );

      // The sawn face inside the bark ring.
      for (var y = 0; y < 460; y++) {
        for (var x = 0; x < 460; x++) {
          final d =
              (Offset(x.toDouble(), y.toDouble()) - const Offset(230, 230))
                  .distance;

          if (d <= woodRadius) {
            image.setPixelRgb(x, y, 214, 190, 152);
          }
        }
      }

      return image;
    }

    test('the outline reaches the outside of the bark, not the inside', () {
      // The sapwood-to-bark step is the strongest colour change on every
      // ray. Taking the strongest edge stopped the outline at 120 and
      // reported a log a third narrower than it is.
      final detection = LogFaceDetector.detect(
        image: barkedFace(woodRadius: 120, barkRadius: 150),
        centre: const Offset(230, 230),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(150, 18));
      expect(detection.ellipse.semiMajor, greaterThan(132));
    });

    test('a thick bark ring is still included', () {
      final detection = LogFaceDetector.detect(
        image: barkedFace(woodRadius: 100, barkRadius: 145),
        centre: const Offset(230, 230),
      )!;

      expect(detection.ellipse.semiMajor, greaterThan(125));
    });

    test('a bare face with no bark is unaffected', () {
      // The change must not push the boundary outwards when there is only
      // one edge to find.
      final detection = LogFaceDetector.detect(
        image: syntheticFace(
          centre: const Offset(200, 200),
          radiusX: 120,
          radiusY: 120,
          faceRgb: const [210, 190, 155],
          backgroundRgb: const [40, 38, 35],
        ),
        centre: const Offset(200, 200),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(120, 12));
    });
  });

  group('robustness', () {
    test('survives sensor noise', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 120,
        radiusY: 120,
        faceRgb: const [200, 180, 150],
        backgroundRgb: const [55, 50, 45],
        noise: 22,
      );

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 200),
      )!;

      expect(detection.ellipse.semiMajor, closeTo(120, 18));
    });

    test('an off-centre tap still finds the same face', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 130,
        radiusY: 130,
        faceRgb: const [210, 190, 155],
        backgroundRgb: const [40, 38, 35],
      );

      // Tapped well off to one side, as a thumb in a timber yard would.
      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(255, 235),
      )!;

      // Re-measuring from the fitted centre is what rescues this: the tap
      // only has to land somewhere on the face.
      expect(
        (detection.ellipse.centre - const Offset(200, 200)).distance,
        lessThan(25),
      );
      expect(detection.ellipse.semiMajor, closeTo(130, 20));
    });

    test('a shadow across the face does not cut the outline short', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 130,
        radiusY: 130,
        faceRgb: const [205, 185, 150],
        backgroundRgb: const [40, 38, 35],
      );

      // Darken the lower half of the face, as a shadow would.
      for (var y = 200; y < 400; y++) {
        for (var x = 0; x < 400; x++) {
          final d =
              (Offset(x.toDouble(), y.toDouble()) - const Offset(200, 200))
                  .distance;
          if (d > 130) continue;

          final p = image.getPixel(x, y);
          image.setPixelRgb(
            x,
            y,
            (p.r * 0.62).round(),
            (p.g * 0.62).round(),
            (p.b * 0.62).round(),
          );
        }
      }

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(200, 170),
      )!;

      // The shadow edge is a hard luminance step straight across the middle.
      // Stopping there would halve the log; the fitted shape must outvote it.
      expect(detection.ellipse.semiMajor, greaterThan(100));
      expect(detection.ellipse.semiMinor, greaterThan(100));
    });
  });

  group('refuses rather than guesses', () {
    test('a blank image yields no detection', () {
      final image = img.Image(width: 300, height: 300);
      img.fill(image, color: img.ColorRgb8(128, 128, 128));

      final detection = LogFaceDetector.detect(
        image: image,
        centre: const Offset(150, 150),
      );

      // Nothing to find. Reporting a confident circle here would send a
      // wrong diameter straight into a volume the user gets paid on.
      if (detection != null) {
        expect(detection.isReliable, isFalse);
      }
    });

    test('rejects a tap outside the image', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 100,
        radiusY: 100,
        faceRgb: const [200, 180, 150],
        backgroundRgb: const [40, 38, 35],
      );

      expect(
        LogFaceDetector.detect(image: image, centre: const Offset(-40, 200)),
        isNull,
      );
      expect(
        LogFaceDetector.detect(image: image, centre: const Offset(900, 200)),
        isNull,
      );
    });

    test('rejects absurd ray counts and tiny images', () {
      final image = syntheticFace(
        centre: const Offset(200, 200),
        radiusX: 100,
        radiusY: 100,
        faceRgb: const [200, 180, 150],
        backgroundRgb: const [40, 38, 35],
      );

      expect(
        LogFaceDetector.detect(
          image: image,
          centre: const Offset(200, 200),
          rayCount: 3,
        ),
        isNull,
      );

      expect(
        LogFaceDetector.detect(
          image: img.Image(width: 8, height: 8),
          centre: const Offset(4, 4),
        ),
        isNull,
      );
    });
  });
}
