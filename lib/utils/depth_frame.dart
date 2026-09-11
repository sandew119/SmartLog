import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// One frame of LiDAR depth, as it arrives from the native scanner.
///
/// The native side is a pump and nothing more: it hands over the raw depth
/// grid, the intrinsics of the image those depths belong to, and the camera
/// pose. Every piece of arithmetic that could silently warp a measurement
/// happens here, in Dart, where it is tested against synthetic scenes on a
/// machine with no device.
///
/// That split is deliberate, and it is the main lesson of the previous
/// attempt: the unprojection convention and the intrinsics rescaling are the
/// two things that produce points which *look* right -- correct count,
/// finite, roughly the right magnitude -- while being systematically wrong.
/// They must not live where they cannot be tested.
class DepthFrame {
  /// Row-major depth values in metres, [width] * [height] long.
  ///
  /// ARKit reports distance along the camera's viewing axis, not radial
  /// distance from the lens.
  final Float32List depths;

  /// Matching `ARConfidenceLevel` raw values (0 low, 1 medium, 2 high), or
  /// null when the device did not supply a confidence map.
  final Uint8List? confidence;

  final int width;
  final int height;

  /// Intrinsics already rescaled to [width] x [height]. Built in
  /// [DepthFrame.fromNative], which is where the rescale is tested.
  final double fx;
  final double fy;
  final double cx;
  final double cy;

  /// Camera space -> world space.
  final Matrix4 cameraTransform;

  /// Dimensions of the full captured image the raw intrinsics describe.
  /// Kept so the UI can relate depth pixels to screen pixels.
  final int imageWidth;
  final int imageHeight;

  final bool trackingReliable;

  /// Why tracking is limited, as ARKit states it -- `initializing`,
  /// `excessiveMotion`, `insufficientFeatures`, `relocalizing` -- or empty
  /// when tracking is normal. Lets the screen say "slow down" instead of a
  /// generic "hold on".
  final String trackingReason;

  /// ARKit frame timestamp, in seconds. Monotonic within a session.
  final double timestamp;

  DepthFrame({
    required this.depths,
    required this.confidence,
    required this.width,
    required this.height,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.cameraTransform,
    required this.imageWidth,
    required this.imageHeight,
    required this.trackingReliable,
    this.trackingReason = '',
    required this.timestamp,
  });

  /// Minimum ARKit confidence accepted. `.medium` drops the worst returns --
  /// silhouette edges, wet dark bark, sunlit surfaces -- without throwing
  /// away most of a normal frame.
  static const int minConfidence = 1;

  /// Depth readings outside this band are not surface: below it is the
  /// sensor's blind zone, above it the returns are too sparse and too noisy
  /// to measure timber from.
  static const double minDepthMetres = 0.12;
  static const double maxDepthMetres = 6.0;

  int get pixelCount => width * height;

  /// Decodes a native payload, returning null rather than throwing on
  /// anything malformed.
  ///
  /// Defensive on purpose. The native side is the one part of this feature
  /// that cannot be tested here, so this layer assumes it may send the wrong
  /// shape -- and a bad frame must degrade to "no reading this tick", never
  /// to a crash in the middle of someone's scan.
  static DepthFrame? fromNative(Map<Object?, Object?> raw) {
    final width = _int(raw['width']);
    final height = _int(raw['height']);

    if (width == null || height == null || width < 8 || height < 8) {
      return null;
    }

    final depths = _floats(raw['depths']);
    if (depths == null || depths.length < width * height) return null;

    final imageWidth = _int(raw['imageWidth']);
    final imageHeight = _int(raw['imageHeight']);

    if (imageWidth == null ||
        imageHeight == null ||
        imageWidth <= 0 ||
        imageHeight <= 0) {
      return null;
    }

    final fx = _double(raw['fx']);
    final fy = _double(raw['fy']);
    final cx = _double(raw['cx']);
    final cy = _double(raw['cy']);

    if (fx == null || fy == null || cx == null || cy == null) return null;
    if (fx <= 0 || fy <= 0) return null;

    // The intrinsics describe the full captured image; the depth grid is a
    // downscaled view of the same optics, so every intrinsic scales by the
    // same ratio. Forgetting this is the classic bug: it yields points with
    // a plausible shape and the wrong size, and a wrong size squares
    // straight into the volume someone is paid on.
    final scaleX = width / imageWidth;
    final scaleY = height / imageHeight;

    final transform = _matrix(raw['transform']);
    if (transform == null) return null;

    final confidence = _bytes(raw['confidence']);

    return DepthFrame(
      depths: depths,
      confidence: (confidence != null && confidence.length >= width * height)
          ? confidence
          : null,
      width: width,
      height: height,
      fx: fx * scaleX,
      fy: fy * scaleY,
      cx: cx * scaleX,
      cy: cy * scaleY,
      cameraTransform: transform,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      trackingReliable: raw['tracking'] == 'normal',
      trackingReason:
          raw['trackingReason'] is String ? raw['trackingReason'] as String : '',
      timestamp: _double(raw['timestamp']) ?? 0,
    );
  }

  /// Depth at a pixel, or null when there is no usable return there.
  double? depthAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return null;

    final index = y * width + x;
    final depth = depths[index];

    if (!depth.isFinite || depth < minDepthMetres || depth > maxDepthMetres) {
      return null;
    }

    final map = confidence;
    if (map != null && map[index] < minConfidence) return null;

    return depth;
  }

  /// The median depth over a square window, which is what any seed reading
  /// should use: one dropped or glinting return at the exact pixel must not
  /// decide where the app thinks the log is.
  double? medianDepthAround(int x, int y, {int radius = 3}) {
    final samples = <double>[];

    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final depth = depthAt(x + dx, y + dy);
        if (depth != null) samples.add(depth);
      }
    }

    if (samples.length < 3) return null;

    samples.sort();
    return samples[samples.length ~/ 2];
  }

  /// Unprojects a pixel into camera space.
  ///
  /// Image coordinates run x-right / y-DOWN; ARKit camera space is
  /// x-right / y-UP / -z-FORWARD. Hence the two sign flips, which are
  /// exactly what this class exists to keep testable.
  Vector3 cameraPointAt(int x, int y, double depth) {
    return Vector3(
      (x - cx) * depth / fx,
      -(y - cy) * depth / fy,
      -depth,
    );
  }

  /// Unprojects a pixel straight into world space, or null when the pixel
  /// carries no usable depth.
  Vector3? worldPointAt(int x, int y) {
    final depth = depthAt(x, y);
    if (depth == null) return null;

    return toWorld(cameraPointAt(x, y, depth));
  }

  Vector3 toWorld(Vector3 cameraPoint) =>
      cameraTransform.transform3(cameraPoint.clone());

  /// Where the camera is, in world space.
  Vector3 get cameraPosition => Vector3(
        cameraTransform.storage[12],
        cameraTransform.storage[13],
        cameraTransform.storage[14],
      );

  /// The direction the camera is looking, in world space. ARKit's camera
  /// looks down its own -Z.
  Vector3 get cameraForward => Vector3(
        -cameraTransform.storage[8],
        -cameraTransform.storage[9],
        -cameraTransform.storage[10],
      ).normalized();

  /// How many depth pixels across an object of [metres] appears at
  /// [distanceMetres]. Used to draw the lock-on ring at the right size.
  double pixelsFor(double metres, double distanceMetres) {
    if (distanceMetres <= 0 || fx <= 0) return 0;
    return metres * fx / distanceMetres;
  }

  // --- decoding helpers ---------------------------------------------------

  static int? _int(Object? value) => value is num ? value.toInt() : null;

  static double? _double(Object? value) {
    if (value is! num) return null;
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }

  static Float32List? _floats(Object? value) {
    if (value is Float32List) return value;
    if (value is Float64List) return Float32List.fromList(value);

    if (value is List) {
      final out = Float32List(value.length);
      for (var i = 0; i < value.length; i++) {
        final v = value[i];
        out[i] = v is num ? v.toDouble() : double.nan;
      }
      return out;
    }

    return null;
  }

  static Uint8List? _bytes(Object? value) {
    if (value is Uint8List) return value;

    if (value is List) {
      final out = Uint8List(value.length);
      for (var i = 0; i < value.length; i++) {
        final v = value[i];
        out[i] = v is num ? v.toInt().clamp(0, 255) : 0;
      }
      return out;
    }

    return null;
  }

  /// Reads a column-major 4x4, which is how both `simd_float4x4` and
  /// vector_math's `Matrix4` store themselves -- so the flat buffer maps
  /// straight across with no transpose.
  static Matrix4? _matrix(Object? value) {
    final floats = _floats(value);
    if (floats == null || floats.length < 16) return null;

    final storage = List<double>.filled(16, 0);
    for (var i = 0; i < 16; i++) {
      final v = floats[i];
      if (!v.isFinite) return null;
      storage[i] = v;
    }

    return Matrix4.fromList(storage);
  }
}

/// A plane fitted through a set of points, with the spread about it.
class PlaneFit {
  /// A point on the plane -- the centroid of what was fitted.
  final Vector3 origin;

  /// Unit normal.
  final Vector3 normal;

  /// Root-mean-square distance of the points from the plane, in metres.
  /// On a sawn face this is a couple of millimetres; on bark, centimetres.
  final double rmsMetres;

  const PlaneFit({
    required this.origin,
    required this.normal,
    required this.rmsMetres,
  });

  double distanceTo(Vector3 point) => (point - origin).dot(normal);

  /// Fits by principal component analysis: the normal is the direction of
  /// least variance.
  ///
  /// Found by power-iterating on `trace*I - C` rather than decomposing `C`
  /// itself. The largest eigenvector of that matrix is the smallest of `C`,
  /// the iteration is a handful of 3x3 multiplies once the covariance is
  /// accumulated, and there is no eigen-solver to get subtly wrong.
  static PlaneFit? fit(List<Vector3> points) {
    if (points.length < 6) return null;

    var mean = Vector3.zero();
    for (final p in points) {
      mean += p;
    }
    mean.scale(1 / points.length);

    var xx = 0.0, xy = 0.0, xz = 0.0, yy = 0.0, yz = 0.0, zz = 0.0;

    for (final p in points) {
      final dx = p.x - mean.x;
      final dy = p.y - mean.y;
      final dz = p.z - mean.z;

      xx += dx * dx;
      xy += dx * dy;
      xz += dx * dz;
      yy += dy * dy;
      yz += dy * dz;
      zz += dz * dz;
    }

    final trace = xx + yy + zz;
    if (!trace.isFinite || trace <= 0) return null;

    // trace >= every eigenvalue, so this shift is positive semi-definite and
    // its dominant eigenvector is the plane normal.
    final a00 = trace - xx, a01 = -xy, a02 = -xz;
    final a11 = trace - yy, a12 = -yz;
    final a22 = trace - zz;

    // Seeded off-axis so a plane lying square to a coordinate axis does not
    // start life on an exact eigenvector of the wrong one.
    var vx = 0.5770, vy = 0.5771, vz = 0.5772;

    for (var i = 0; i < 64; i++) {
      final nx = a00 * vx + a01 * vy + a02 * vz;
      final ny = a01 * vx + a11 * vy + a12 * vz;
      final nz = a02 * vx + a12 * vy + a22 * vz;

      final magnitude = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (!magnitude.isFinite || magnitude < 1e-12) return null;

      vx = nx / magnitude;
      vy = ny / magnitude;
      vz = nz / magnitude;
    }

    final normal = Vector3(vx, vy, vz);

    var squared = 0.0;
    for (final p in points) {
      final d = (p - mean).dot(normal);
      squared += d * d;
    }

    final rms = math.sqrt(squared / points.length);
    if (!rms.isFinite) return null;

    return PlaneFit(origin: mean, normal: normal, rmsMetres: rms);
  }
}

/// Two unit vectors spanning the plane across [axis], for measuring angles
/// around it.
({Vector3 u, Vector3 v}) perpendicularBasis(Vector3 axis) {
  final direction = axis.normalized();

  // Cross with whichever world axis the direction is least aligned to, so
  // the cross product is never near zero.
  final helper = direction.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);

  final u = direction.cross(helper).normalized();
  final v = direction.cross(u).normalized();

  return (u: u, v: v);
}
