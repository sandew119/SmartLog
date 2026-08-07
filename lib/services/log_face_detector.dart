import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../models/log_face_outline.dart';

/// The result of tracing a log face, with enough information for the UI to
/// decide whether to trust it.
class LogFaceDetection {
  final LogFaceOutline outline;

  /// Fraction of rays that found a clear edge, 0..1. Low means the face and
  /// its surroundings were too similar in brightness -- usually a log lying
  /// on sawdust, or a photo taken in flat shade.
  final double confidence;

  final int rayCount;
  final int weakRays;

  const LogFaceDetection({
    required this.outline,
    required this.confidence,
    required this.rayCount,
    required this.weakRays,
  });

  /// Below this the UI should say so and invite the user to drag the outline
  /// rather than quietly packing boards against a guess.
  bool get isReliable => confidence >= 0.7;
}

/// Finds the boundary of a log's cut face by casting rays out from a point
/// the user tapped.
///
/// Why rays rather than a segmentation model: the sawn face is pale and
/// everything around it -- bark, ground, shadow -- is dark, which makes this
/// one of the easiest edges in computer vision. Casting rays from a known
/// interior point exploits that directly, and it produces a polygon, which is
/// exactly what the packing engine consumes. No model to ship, no training
/// data, runs in milliseconds, and when it is wrong you can see precisely
/// which ray misfired and drag that handle.
///
/// The one assumption is face-brighter-than-surroundings. It holds for fresh
/// sawn timber. [detect] reports [LogFaceDetection.confidence] so the UI can
/// catch the cases where it doesn't.
class LogFaceDetector {
  /// Detection runs on a downscaled copy: it is much faster, it smooths
  /// sensor noise for free, and it means the tuning constants below mean the
  /// same thing regardless of the phone's megapixel count.
  static const int _workingSize = 512;

  /// Half-width of the window either side of a candidate edge, in working
  /// pixels. Wide enough to ignore grain, narrow enough to sit on the bark.
  static const int _edgeWindow = 4;

  /// Ignore the first few pixels: the user's fingertip is imprecise and the
  /// pith at the centre of a log is often dark enough to look like an edge.
  static const int _minRadius = 8;

  /// A drop of at least this much luminance (0-255) counts as a real
  /// boundary rather than a shadow across the face.
  static const double _minEdgeStrength = 12;

  static LogFaceDetection? detect({
    required img.Image image,
    required Offset centre,
    int rayCount = 72,
  }) {
    if (rayCount < 8) return null;
    if (image.width < 16 || image.height < 16) return null;

    final scale = _workingSize / math.max(image.width, image.height);
    final working = scale < 1
        ? img.copyResize(
            image,
            width: (image.width * scale).round(),
            height: (image.height * scale).round(),
          )
        : image;

    final workingScale = working.width / image.width;
    final origin = Offset(centre.dx * workingScale, centre.dy * workingScale);

    if (origin.dx < 0 ||
        origin.dy < 0 ||
        origin.dx >= working.width ||
        origin.dy >= working.height) {
      return null;
    }

    final luminance = _luminanceGrid(working);

    final radii = <double>[];
    final strengths = <double>[];

    for (var i = 0; i < rayCount; i++) {
      final angle = 2 * math.pi * i / rayCount;
      final hit = _traceRay(
        luminance: luminance,
        width: working.width,
        height: working.height,
        origin: origin,
        angle: angle,
      );

      radii.add(hit.radius);
      strengths.add(hit.strength);
    }

    final weak = strengths.where((s) => s < _minEdgeStrength).length;

    // A single ray that shot off into a bright patch of sky, or stopped dead
    // on a shadow, would otherwise put a spike or a bite in the outline and
    // corrupt the packing. The median filter removes those without rounding
    // off genuine flat spots, which are the shape detail worth keeping.
    final cleaned = _smooth(_medianFilter(radii));

    final outline = LogFaceOutline.fromRadii(origin, cleaned);
    if (!outline.isValid || outline.area <= 0) return null;

    // Back to the coordinates of the image that was passed in, so the caller
    // can draw the outline over the full-resolution photo.
    final restored = outline.scaled(1 / workingScale);

    return LogFaceDetection(
      outline: restored,
      confidence: (rayCount - weak) / rayCount,
      rayCount: rayCount,
      weakRays: weak,
    );
  }

  /// Precomputed once per detection: every ray re-reads overlapping pixels,
  /// and going through the image package's per-pixel accessor for each of
  /// them is the difference between instant and visibly slow.
  static List<double> _luminanceGrid(img.Image image) {
    final grid = List<double>.filled(image.width * image.height, 0);

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        grid[y * image.width + x] =
            0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
      }
    }

    return grid;
  }

  static ({double radius, double strength}) _traceRay({
    required List<double> luminance,
    required int width,
    required int height,
    required Offset origin,
    required double angle,
  }) {
    final dx = math.cos(angle);
    final dy = math.sin(angle);

    // Stop at the frame edge.
    final maxRadius = _maxRadius(origin, dx, dy, width, height);
    if (maxRadius <= _minRadius + _edgeWindow * 2) {
      return (radius: maxRadius, strength: 0);
    }

    double bestStrength = 0;
    double bestRadius = maxRadius;

    for (var r = _minRadius + _edgeWindow;
        r < maxRadius - _edgeWindow;
        r++) {
      double inner = 0;
      double outer = 0;

      for (var w = 1; w <= _edgeWindow; w++) {
        inner += _sample(luminance, width, height, origin, dx, dy, r - w);
        outer += _sample(luminance, width, height, origin, dx, dy, r + w);
      }

      // Positive where the image goes bright-to-dark travelling outwards,
      // which is the face giving way to bark or ground.
      final strength = (inner - outer) / _edgeWindow;

      if (strength > bestStrength) {
        bestStrength = strength;
        bestRadius = r.toDouble();
      }
    }

    return (radius: bestRadius, strength: bestStrength);
  }

  static double _maxRadius(
    Offset origin,
    double dx,
    double dy,
    int width,
    int height,
  ) {
    double limit = math.max(width, height).toDouble();

    if (dx > 1e-9) {
      limit = math.min(limit, (width - 1 - origin.dx) / dx);
    } else if (dx < -1e-9) {
      limit = math.min(limit, -origin.dx / dx);
    }

    if (dy > 1e-9) {
      limit = math.min(limit, (height - 1 - origin.dy) / dy);
    } else if (dy < -1e-9) {
      limit = math.min(limit, -origin.dy / dy);
    }

    return math.max(0, limit);
  }

  static double _sample(
    List<double> luminance,
    int width,
    int height,
    Offset origin,
    double dx,
    double dy,
    num distance,
  ) {
    final x = (origin.dx + dx * distance).round().clamp(0, width - 1);
    final y = (origin.dy + dy * distance).round().clamp(0, height - 1);

    return luminance[y * width + x];
  }

  /// Replaces each radius with the median of itself and its neighbours,
  /// wrapping around the ring.
  static List<double> _medianFilter(List<double> radii, {int window = 2}) {
    return List<double>.generate(radii.length, (i) {
      final neighbourhood = <double>[];

      for (var offset = -window; offset <= window; offset++) {
        neighbourhood.add(radii[(i + offset + radii.length) % radii.length]);
      }

      neighbourhood.sort();
      return neighbourhood[neighbourhood.length ~/ 2];
    });
  }

  /// Light circular blur, so the traced edge follows the wood rather than
  /// stepping between whole pixels.
  static List<double> _smooth(List<double> radii) {
    return List<double>.generate(radii.length, (i) {
      final previous = radii[(i - 1 + radii.length) % radii.length];
      final next = radii[(i + 1) % radii.length];

      return (previous + 2 * radii[i] + next) / 4;
    });
  }
}
