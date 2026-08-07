import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Converts between a photo's pixel coordinates and the box it is drawn in
/// with `BoxFit.contain`.
///
/// Extracted from the tracing screen and made a pure value type on purpose.
/// The first version of this lived as private methods on the widget's State
/// and had a bug that made the screen completely unusable: the mapper needed
/// the image's dimensions, and those were only obtained *after* a successful
/// detection, which could not happen until a tap had been mapped. Nothing was
/// testable, so nothing caught it. This is testable.
class FittedImageMapper {
  /// The photo's true pixel dimensions.
  final Size imageSize;

  /// The widget the photo is being painted into.
  final Size boxSize;

  const FittedImageMapper({required this.imageSize, required this.boxSize});

  bool get _isUsable =>
      imageSize.width > 0 &&
      imageSize.height > 0 &&
      boxSize.width > 0 &&
      boxSize.height > 0;

  /// Uniform scale factor from image pixels to screen pixels.
  double get scale {
    if (!_isUsable) return 1;

    return math.min(
      boxSize.width / imageSize.width,
      boxSize.height / imageSize.height,
    );
  }

  /// Where the photo actually sits inside the box, letterboxed and centred.
  Rect get displayRect {
    if (!_isUsable) return Offset.zero & boxSize;

    final w = imageSize.width * scale;
    final h = imageSize.height * scale;

    return Rect.fromLTWH((boxSize.width - w) / 2, (boxSize.height - h) / 2, w, h);
  }

  /// A tap in the widget, in image pixels. Null when the tap landed on the
  /// letterbox bars rather than the photo.
  Offset? toImage(Offset local) {
    if (!_isUsable) return null;

    final rect = displayRect;
    if (!rect.contains(local)) return null;

    return Offset(
      (local.dx - rect.left) / scale,
      (local.dy - rect.top) / scale,
    );
  }

  /// An image-space point in widget coordinates, for painting overlays.
  Offset toScreen(Offset image) {
    if (!_isUsable) return image;

    final rect = displayRect;
    return Offset(rect.left + image.dx * scale, rect.top + image.dy * scale);
  }

  /// A length in image pixels expressed in screen pixels, so a defect circle
  /// keeps its size relative to the log rather than the screen.
  double lengthToScreen(double imageLength) => imageLength * scale;
}
