import 'dart:math' as math;
import 'dart:typed_data';

import 'package:smartlog2/utils/depth_frame.dart';
import 'package:vector_math/vector_math_64.dart';

/// Renders depth frames of known scenes, so the geometry that turns depth
/// into a girth can be checked against an answer worked out on paper.
///
/// This is the substitute for a device. Every constant in [FaceScanner] was
/// chosen against scenes built here, and a change that breaks a real scan
/// should break one of these first.
class SyntheticCamera {
  final int width;
  final int height;

  /// Intrinsics of the depth grid itself.
  final double fx;
  final double fy;
  final double cx;
  final double cy;

  /// How much larger the full captured image is than the depth grid. The
  /// payload carries the full image's intrinsics, exactly as ARKit reports
  /// them, so the rescale gets exercised on every frame built here.
  final int imageScale;

  final Matrix4 transform;

  SyntheticCamera({
    this.width = 128,
    this.height = 96,
    this.fx = 110,
    this.fy = 110,
    double? cx,
    double? cy,
    this.imageScale = 15,
    Matrix4? transform,
  })  : cx = cx ?? width / 2,
        cy = cy ?? height / 2,
        transform = transform ?? Matrix4.identity();

  /// Direction of the ray through a pixel, in camera space, scaled so that
  /// its z is -1 -- which makes the ray parameter equal the depth ARKit
  /// would report.
  Vector3 ray(int x, int y) => Vector3(
        (x - cx) / fx,
        -(y - cy) / fy,
        -1,
      );

  DepthFrame frame(
    Float32List depths, {
    bool tracking = true,
    double timestamp = 1.0,
  }) {
    return DepthFrame.fromNative({
      'width': width,
      'height': height,
      'depths': depths,
      'confidence': null,
      'imageWidth': width * imageScale,
      'imageHeight': height * imageScale,
      'fx': fx * imageScale,
      'fy': fy * imageScale,
      'cx': cx * imageScale,
      'cy': cy * imageScale,
      'transform': Float32List.fromList(
        transform.storage.map((v) => v.toDouble()).toList(),
      ),
      'tracking': tracking ? 'normal' : 'limited',
      'trackingReason': tracking ? '' : 'excessiveMotion',
      'timestamp': timestamp,
    })!;
  }

  /// A flat face floating in front of a background wall.
  ///
  /// [outline] gives the face's radius at an angle measured in its own
  /// plane, so a circle, an ellipse and a lobed log end are all one call.
  Float32List renderFace({
    required Vector3 centre,
    required Vector3 normal,
    required double Function(double angle) outline,
    double backgroundDepth = 4.0,
  }) {
    final unit = normal.normalized();

    // A basis in the face's plane. Must match the convention the tracer
    // uses, or "radius at angle" would mean two different things.
    final helper = unit.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
    final u = unit.cross(helper).normalized();
    final v = unit.cross(u).normalized();

    final depths = Float32List(width * height);
    final planeOffset = centre.dot(unit);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        depths[y * width + x] = backgroundDepth;

        final direction = ray(x, y);
        final denominator = direction.dot(unit);

        if (denominator.abs() < 1e-9) continue;

        final s = planeOffset / denominator;
        if (s <= 0 || s >= backgroundDepth) continue;

        final point = direction * s;
        final offset = point - centre;

        final a = offset.dot(u);
        final b = offset.dot(v);

        final radius = math.sqrt(a * a + b * b);

        var angle = math.atan2(b, a);
        if (angle < 0) angle += 2 * math.pi;

        if (radius <= outline(angle)) depths[y * width + x] = s;
      }
    }

    return depths;
  }

  /// The curved side of a log lying across the view -- what the scanner sees
  /// when the user points at the trunk instead of the end.
  Float32List renderCylinderSide({
    required Vector3 centre,
    required Vector3 axis,
    required double radius,
    double backgroundDepth = 4.0,
  }) {
    final direction = axis.normalized();
    final depths = Float32List(width * height);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        depths[y * width + x] = backgroundDepth;

        final d = ray(x, y);

        // Ray-cylinder intersection, with the component along the axis
        // removed from both the ray and the offset to the centre.
        final dPerp = d - direction * d.dot(direction);
        final oc = -centre;
        final ocPerp = oc - direction * oc.dot(direction);

        final a = dPerp.dot(dPerp);
        if (a < 1e-12) continue;

        final b = 2 * dPerp.dot(ocPerp);
        final c = ocPerp.dot(ocPerp) - radius * radius;

        final discriminant = b * b - 4 * a * c;
        if (discriminant < 0) continue;

        final root = math.sqrt(discriminant);
        final s = (-b - root) / (2 * a);

        if (s <= 0 || s >= backgroundDepth) continue;

        depths[y * width + x] = s;
      }
    }

    return depths;
  }
}

/// The perimeter of a star-shaped outline, integrated finely enough to be
/// the reference a traced girth is judged against.
double truePerimeter(double Function(double angle) outline, {int steps = 4000}) {
  var total = 0.0;

  for (var i = 0; i < steps; i++) {
    final a0 = 2 * math.pi * i / steps;
    final a1 = 2 * math.pi * (i + 1) / steps;

    final r0 = outline(a0);
    final r1 = outline(a1);

    final x0 = r0 * math.cos(a0), y0 = r0 * math.sin(a0);
    final x1 = r1 * math.cos(a1), y1 = r1 * math.sin(a1);

    total += math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
  }

  return total;
}
