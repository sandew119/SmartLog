import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'synthetic_depth.dart';

extension SyntheticLogs on SyntheticCamera {
  /// The side of a log whose radius changes along its length, placed in WORLD
  /// coordinates and rendered through this camera's pose.
  ///
  /// [origin] is the centre of the near end and [axis] the direction the log
  /// runs in; [radiusAt] gives the radius at a distance along it. A surface of
  /// revolution has no closed-form ray intersection once the radius varies,
  /// so this sphere-traces it: each step advances by the distance to the
  /// surface, which is safe and converges in a dozen steps for anything as
  /// smooth as timber.
  Float32List renderLogSide({
    required Vector3 origin,
    required Vector3 axis,
    required double Function(double along) radiusAt,
    required double length,
    double backgroundDepth = 6.0,
  }) {
    final unit = axis.normalized();
    final rotation = transform.getRotation();

    final eye = Vector3(
      transform.storage[12],
      transform.storage[13],
      transform.storage[14],
    );

    final depths = Float32List(width * height);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final direction = rotation * ray(x, y);
        final speed = direction.length;

        var s = 0.0;
        var hit = backgroundDepth;

        for (var step = 0; step < 60; step++) {
          final p = eye + direction * s;
          final offset = p - origin;

          final along = offset.dot(unit);
          final radial = (offset - unit * along).length;

          // Past the ends there is no log to hit; the end faces are rendered
          // separately.
          final a = along.clamp(0.0, length).toDouble();
          final r = radiusAt(a);

          // How far to the surface, and how steeply it leans.
          final gap = radial - r;
          final lean = (radiusAt((a + 0.01).clamp(0.0, length).toDouble()) -
                  radiusAt((a - 0.01).clamp(0.0, length).toDouble())) /
              0.02;

          if (gap < 1e-4 && along >= 0 && along <= length) {
            hit = s;
            break;
          }

          final advance =
              math.max(gap.abs(), 2e-4) / math.sqrt(1 + lean * lean) / speed;

          s += advance;
          if (s > backgroundDepth) break;
        }

        depths[y * width + x] = hit;
      }
    }

    return depths;
  }
}
