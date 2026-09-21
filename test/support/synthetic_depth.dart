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

  /// The payload the native side sends for a frame: exactly what
  /// [DepthFrame.fromNative] reads, so a test can deliver it over a channel.
  Map<String, Object?> payload(
    Float32List depths, {
    bool tracking = true,
    double timestamp = 1.0,
    Uint8List? confidence,
  }) {
    return {
      'width': width,
      'height': height,
      'depths': depths,
      'confidence': confidence,
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
    };
  }

  DepthFrame frame(
    Float32List depths, {
    bool tracking = true,
    double timestamp = 1.0,
    Uint8List? confidence,
  }) {
    return DepthFrame.fromNative(
      payload(
        depths,
        tracking: tracking,
        timestamp: timestamp,
        confidence: confidence,
      ),
    )!;
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

/// The nearer of two rendered scenes at every pixel -- how separate objects
/// in one view occlude each other.
Float32List nearest(Float32List a, Float32List b) {
  final out = Float32List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = a[i] < b[i] ? a[i] : b[i];
  }
  return out;
}

/// Standard normal deviate (Box-Muller), from a seeded generator so a noisy
/// test is the same test on every run.
double gaussian(math.Random rng) {
  final u = 1 - rng.nextDouble();
  final v = rng.nextDouble();
  return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
}

/// What a real LiDAR depth map does to a perfect one.
///
/// The clean renders above are exact, which is exactly why the scanner's
/// constants once looked fine and then struggled on a phone. A real map:
///
/// - carries noise that grows with range, and is smooth over a couple of
///   pixels rather than independent per pixel (ARKit's depth is filtered);
/// - smears across every depth step, leaving pixels part-way between the
///   object and what is behind it;
/// - and reports low confidence along exactly those steps.
///
/// The figures are deliberately on the harsh side of what is published for an
/// iPhone 13 Pro, because a scanner that survives this survives the yard.
class SensorModel {
  /// Noise standard deviation at zero range and its growth per metre.
  final double baseSigmaMetres;
  final double sigmaPerMetre;

  /// A step in depth bigger than this is an edge.
  final double edgeStepMetres;

  /// Chance an edge pixel is reported at low confidence.
  final double edgeDropout;

  const SensorModel({
    this.baseSigmaMetres = 0.0015,
    this.sigmaPerMetre = 0.004,
    this.edgeStepMetres = 0.03,
    this.edgeDropout = 0.6,
  });

  static const SensorModel clean = SensorModel(
    baseSigmaMetres: 0,
    sigmaPerMetre: 0,
    edgeDropout: 0,
  );

  ({Float32List depths, Uint8List confidence}) apply(
    Float32List source,
    int width,
    int height,
    math.Random rng,
  ) {
    final depths = Float32List.fromList(source);
    final confidence = Uint8List(width * height)..fillRange(0, width * height, 2);

    bool inside(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

    // Edge smear and confidence, worked out against the clean scene.
    final smeared = Float32List.fromList(source);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final here = source[y * width + x];
        var edge = false;

        for (var dy = -1; dy <= 1 && !edge; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (!inside(x + dx, y + dy)) continue;
            if ((source[(y + dy) * width + x + dx] - here).abs() >
                edgeStepMetres) {
              edge = true;
              break;
            }
          }
        }

        if (!edge) continue;

        var total = 0.0;
        var count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (!inside(x + dx, y + dy)) continue;
            total += source[(y + dy) * width + x + dx];
            count++;
          }
        }

        smeared[y * width + x] = total / count;

        if (rng.nextDouble() < edgeDropout) confidence[y * width + x] = 0;
      }
    }

    // Noise, smooth over ~3 pixels: white noise averaged over a 3x3 window,
    // scaled back up so the standard deviation is what was asked for.
    final white = Float32List(width * height);
    for (var i = 0; i < white.length; i++) {
      white[i] = gaussian(rng).toDouble();
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var total = 0.0;
        var count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (!inside(x + dx, y + dy)) continue;
            total += white[(y + dy) * width + x + dx];
            count++;
          }
        }

        final d = smeared[y * width + x];
        final sigma = baseSigmaMetres + sigmaPerMetre * d;
        depths[y * width + x] = d + (total / count) * 3 * sigma;
      }
    }

    return (depths: depths, confidence: confidence);
  }
}

extension SyntheticScenes on SyntheticCamera {
  /// A flat ground plane [below] metres under the camera, out to [reach].
  Float32List renderGround({double below = 1.2, double reach = 8}) {
    return renderFace(
      centre: Vector3(0, -below, -1),
      normal: Vector3(0, 1, 0),
      outline: (_) => 1e9,
      backgroundDepth: reach,
    );
  }

  /// A frame of [scene] as the sensor would report it.
  DepthFrame sensedFrame(
    Float32List scene,
    math.Random rng, {
    SensorModel model = const SensorModel(),
    double timestamp = 1.0,
    bool tracking = true,
  }) {
    final sensed = model.apply(scene, width, height, rng);

    return frame(
      sensed.depths,
      confidence: sensed.confidence,
      timestamp: timestamp,
      tracking: tracking,
    );
  }
}

extension WorldScenes on SyntheticCamera {
  /// A flat face placed in WORLD coordinates and rendered through this
  /// camera's pose. The plain [SyntheticCamera.renderFace] takes camera-space
  /// coordinates, which is fine for a camera at the origin but awkward for
  /// one tilted down at a log end on the ground.
  Float32List renderWorldFace({
    required Vector3 centre,
    required Vector3 normal,
    required double Function(double angle) outline,
    double backgroundDepth = 6.0,
  }) {
    final inverse = Matrix4.inverted(transform);

    return renderFace(
      centre: inverse.transformed3(centre),
      normal: inverse.rotated3(normal),
      outline: outline,
      backgroundDepth: backgroundDepth,
    );
  }

  Float32List renderWorldGround({double y = -1.1, double reach = 8}) {
    return renderWorldFace(
      centre: Vector3(0, y, 0),
      normal: Vector3(0, 1, 0),
      outline: (_) => 1e9,
      backgroundDepth: reach,
    );
  }
}
