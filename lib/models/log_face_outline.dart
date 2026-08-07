import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// The traced boundary of a log's cut face.
///
/// This is the thing the old cutting engine never had. It only ever knew one
/// number -- a diameter -- and packed boards into a perfect circle. A real
/// log face is oval, flat on one side, or dented where a branch was, and all
/// of that is yield the circle model throws away.
///
/// Deliberately a plain value type over a list of points, with no dependency
/// on the camera, the image decoder, or Flutter widgets: the packing maths is
/// the part that has to be provably right, so it must be testable without any
/// of that.
///
/// Points are in whatever unit the caller is working in. Straight out of the
/// detector they are pixels; [scaledToGirth] converts to inches.
class LogFaceOutline {
  final List<Offset> points;

  const LogFaceOutline(this.points);

  /// A regular polygon approximating a circle of [diameter].
  ///
  /// The fallback for when the user skips the photo. Having the no-photo path
  /// produce an outline too means the engine has exactly one shape model
  /// instead of a circle branch and a polygon branch that can disagree.
  factory LogFaceOutline.circle(double diameter, {int segments = 72}) {
    final radius = diameter / 2;

    return LogFaceOutline(
      List.generate(segments, (i) {
        final angle = 2 * math.pi * i / segments;
        return Offset(
          radius + radius * math.cos(angle),
          radius + radius * math.sin(angle),
        );
      }),
    );
  }

  /// An outline built from a radius per equally-spaced ray, which is what the
  /// detector produces.
  factory LogFaceOutline.fromRadii(Offset centre, List<double> radii) {
    return LogFaceOutline(
      List.generate(radii.length, (i) {
        final angle = 2 * math.pi * i / radii.length;
        return Offset(
          centre.dx + radii[i] * math.cos(angle),
          centre.dy + radii[i] * math.sin(angle),
        );
      }),
    );
  }

  bool get isValid => points.length >= 3;

  /// Shoelace area. Always positive -- winding direction is an accident of
  /// how the points were collected and must not flip the sign of a yield.
  double get area {
    if (!isValid) return 0;

    double sum = 0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      sum += a.dx * b.dy - b.dx * a.dy;
    }

    return sum.abs() / 2;
  }

  double get perimeter {
    if (points.length < 2) return 0;

    double sum = 0;
    for (var i = 0; i < points.length; i++) {
      sum += (points[(i + 1) % points.length] - points[i]).distance;
    }

    return sum;
  }

  /// Area centroid, not the average of the vertices: the latter drifts toward
  /// wherever the points happen to be densest, which for a ray-traced outline
  /// is the side with the most detail.
  Offset get centroid {
    if (!isValid) return Offset.zero;

    double cx = 0;
    double cy = 0;
    double signedArea = 0;

    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      final cross = a.dx * b.dy - b.dx * a.dy;

      signedArea += cross;
      cx += (a.dx + b.dx) * cross;
      cy += (a.dy + b.dy) * cross;
    }

    // Degenerate (zero-area) outline: fall back to the vertex mean rather
    // than dividing by zero.
    if (signedArea.abs() < 1e-12) {
      final sum = points.reduce((a, b) => a + b);
      return Offset(sum.dx / points.length, sum.dy / points.length);
    }

    signedArea /= 2;
    return Offset(cx / (6 * signedArea), cy / (6 * signedArea));
  }

  Rect get bounds {
    if (points.isEmpty) return Rect.zero;

    double minX = points.first.dx, maxX = points.first.dx;
    double minY = points.first.dy, maxY = points.first.dy;

    for (final p in points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Longest and shortest widths through the centroid. The gap between them
  /// is exactly the ovalness the circle model was discarding.
  ({double major, double minor}) get axes {
    if (!isValid) return (major: 0, minor: 0);

    final c = centroid;
    double maxSpan = 0;
    double minSpan = double.infinity;

    // Half-turn is enough: a chord through the centre is the same line when
    // measured from either end.
    for (var deg = 0; deg < 180; deg += 2) {
      final angle = deg * math.pi / 180;
      final dir = Offset(math.cos(angle), math.sin(angle));

      double forward = 0;
      double backward = 0;

      for (final p in points) {
        final projection = (p - c).dx * dir.dx + (p - c).dy * dir.dy;
        forward = math.max(forward, projection);
        backward = math.min(backward, projection);
      }

      final span = forward - backward;
      maxSpan = math.max(maxSpan, span);
      minSpan = math.min(minSpan, span);
    }

    return (major: maxSpan, minor: minSpan);
  }

  /// Even-odd ray casting. Points exactly on an edge may land either way,
  /// which is fine here: the packing test insets boards before asking.
  bool contains(Offset point) {
    if (!isValid) return false;

    bool inside = false;

    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final a = points[i];
      final b = points[j];

      final straddles = (a.dy > point.dy) != (b.dy > point.dy);
      if (!straddles) continue;

      final crossingX =
          (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx;

      if (point.dx < crossingX) inside = !inside;
    }

    return inside;
  }

  /// True when the whole rectangle lies inside the outline.
  ///
  /// Corners alone are not enough: on a concave face -- the dent where a
  /// branch came off -- a board can have all four corners inside and still
  /// bridge straight over the notch. So edges are sampled too.
  bool containsRect(Rect rect, {int samplesPerEdge = 4}) {
    if (!isValid) return false;

    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ];

    for (final corner in corners) {
      if (!contains(corner)) return false;
    }

    for (var i = 1; i < samplesPerEdge; i++) {
      final t = i / samplesPerEdge;

      final samples = [
        Offset(rect.left + rect.width * t, rect.top),
        Offset(rect.left + rect.width * t, rect.bottom),
        Offset(rect.left, rect.top + rect.height * t),
        Offset(rect.right, rect.top + rect.height * t),
      ];

      for (final sample in samples) {
        if (!contains(sample)) return false;
      }
    }

    return true;
  }

  LogFaceOutline translated(Offset delta) =>
      LogFaceOutline([for (final p in points) p + delta]);

  LogFaceOutline scaled(double factor) =>
      LogFaceOutline([for (final p in points) p * factor]);

  /// Rotates about [origin], defaulting to the outline's own centroid.
  LogFaceOutline rotated(double radians, {Offset? origin}) {
    final o = origin ?? centroid;
    final cos = math.cos(radians);
    final sin = math.sin(radians);

    return LogFaceOutline([
      for (final p in points)
        Offset(
          o.dx + (p.dx - o.dx) * cos - (p.dy - o.dy) * sin,
          o.dy + (p.dx - o.dx) * sin + (p.dy - o.dy) * cos,
        ),
    ]);
  }

  /// Converts a pixel-space outline into inches using the girth the user
  /// already measured with their tape.
  ///
  /// This is what makes the photo work without LiDAR. A photograph carries
  /// shape but no scale -- a small log up close and a big log far away are
  /// the same picture. Most apps solve it by making you put a coin in frame.
  /// Here the tape reading *is* the real perimeter, and the traced outline is
  /// that same perimeter in pixels, so the ratio is the scale. The user does
  /// no extra work at all.
  ///
  /// Returns null when there is nothing to scale from, rather than dividing
  /// by zero and producing an infinite log.
  LogFaceOutline? scaledToGirth(double girthInches) {
    if (!isValid || girthInches <= 0) return null;

    final pixelPerimeter = perimeter;
    if (pixelPerimeter <= 0) return null;

    final inchesPerPixel = girthInches / pixelPerimeter;

    // Normalised to the bounding box origin so the packing engine can work
    // in a plain first-quadrant coordinate space.
    final scaledPoints = [for (final p in points) p * inchesPerPixel];
    final scaled = LogFaceOutline(scaledPoints);
    final b = scaled.bounds;

    return scaled.translated(Offset(-b.left, -b.top));
  }

  /// The diameter of the circle the old engine would have used, for showing
  /// the user what the outline gained them.
  double get equivalentCircleDiameter => 2 * math.sqrt(area / math.pi);
}
