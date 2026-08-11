import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Why an image is not good enough to classify from.
enum ImageQualityFault { tooSmall, tooBlurred, tooDark, tooBright }

class ImageQuality {
  /// Sharpness, as the variance of the Laplacian. Higher is sharper.
  final double sharpness;

  /// Mean luminance, 0..255.
  final double brightness;

  final int width;
  final int height;

  final ImageQualityFault? fault;

  const ImageQuality({
    required this.sharpness,
    required this.brightness,
    required this.width,
    required this.height,
    this.fault,
  });

  bool get isUsable => fault == null;

  /// What to tell the user, and what to do about it.
  ///
  /// Never "invalid image": every message names the thing they can change,
  /// because the user is standing in front of the log and can simply take
  /// another photograph.
  String? get message => switch (fault) {
        null => null,
        ImageQualityFault.tooSmall =>
          "This picture is too small to read the surface from. Use the "
              "camera rather than a screenshot or a shared copy.",
        ImageQualityFault.tooBlurred =>
          "This picture is blurred. Hold the phone still, tap the log to "
              "focus, and take it again.",
        ImageQualityFault.tooDark =>
          "This picture is too dark to tell a shadow from rot. Move into "
              "better light or turn the flash on.",
        ImageQualityFault.tooBright =>
          "This picture is washed out by the light. Shade the log or move "
              "so the sun is behind you.",
      };
}

/// Checks whether a photograph can support a defect classification.
///
/// This exists because a model will happily return a confident answer for a
/// blurred, dark photograph of nothing at all -- it has no way to say "I
/// cannot see". Refusing the image before inference is the only place that
/// judgement can be made, and a wrong answer about rot is worse than no
/// answer.
class ImageQualityChecker {
  /// The specification names 1920x1080. Applied to the long side, since a
  /// portrait photograph of a log end is the normal way to hold a phone.
  static const int minLongSide = 1920;
  static const int minShortSide = 1080;

  /// Laplacian variance below this reads as out of focus.
  ///
  /// Tuned on downscaled greyscale, so it means the same thing regardless of
  /// the phone's megapixel count. Timber is a high-texture subject: a sharp
  /// photograph of bark scores far above this, and anything below it has
  /// genuinely lost the grain.
  static const double minSharpness = 55;

  static const double minBrightness = 45;
  static const double maxBrightness = 225;

  /// Long side of the copy the measurements are taken on.
  static const int _workingSize = 512;

  static ImageQuality assess(
    img.Image image, {
    bool enforceResolution = true,
  }) {
    final longSide = math.max(image.width, image.height);
    final shortSide = math.min(image.width, image.height);

    // Downscale first so sharpness and brightness are comparable between a
    // 48MP flagship and a budget phone.
    final scale = longSide > _workingSize ? _workingSize / longSide : 1.0;

    final work = scale < 1.0
        ? img.copyResize(
            image,
            width: math.max(1, (image.width * scale).round()),
            height: math.max(1, (image.height * scale).round()),
          )
        : image;

    final grey = _greyscale(work);

    final brightness = _mean(grey);
    final sharpness = _laplacianVariance(grey, work.width, work.height);

    ImageQualityFault? fault;

    if (enforceResolution &&
        (longSide < minLongSide || shortSide < minShortSide)) {
      fault = ImageQualityFault.tooSmall;
    } else if (brightness < minBrightness) {
      fault = ImageQualityFault.tooDark;
    } else if (brightness > maxBrightness) {
      fault = ImageQualityFault.tooBright;
    } else if (sharpness < minSharpness) {
      // Checked last: a photograph that is nearly black also has almost no
      // measurable detail, and "it is too dark" is the useful thing to say.
      fault = ImageQualityFault.tooBlurred;
    }

    return ImageQuality(
      sharpness: sharpness,
      brightness: brightness,
      width: image.width,
      height: image.height,
      fault: fault,
    );
  }

  static List<double> _greyscale(img.Image image) {
    final out = List<double>.filled(image.width * image.height, 0);

    var i = 0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final p = image.getPixel(x, y);
        // Rec. 601 luma: green carries most of the perceived detail, so a
        // plain channel average would understate the sharpness of a subject
        // as green-poor as bark.
        out[i++] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }

    return out;
  }

  static double _mean(List<double> values) {
    if (values.isEmpty) return 0;

    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }

    return sum / values.length;
  }

  /// Variance of the 4-neighbour Laplacian.
  ///
  /// The standard focus measure: the Laplacian responds to edges, and a
  /// sharp image has a wide spread of responses while a blurred one has
  /// almost none. Variance rather than mean because the mean of a Laplacian
  /// is close to zero whatever the image.
  static double _laplacianVariance(List<double> grey, int width, int height) {
    if (width < 3 || height < 3) return 0;

    final responses = <double>[];

    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final i = y * width + x;

        final value = -4 * grey[i] +
            grey[i - 1] +
            grey[i + 1] +
            grey[i - width] +
            grey[i + width];

        responses.add(value);
      }
    }

    if (responses.isEmpty) return 0;

    final mean = _mean(responses);

    var sum = 0.0;
    for (final r in responses) {
      final d = r - mean;
      sum += d * d;
    }

    return sum / responses.length;
  }
}
