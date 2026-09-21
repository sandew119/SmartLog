import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Turns a closed ring of points on a log end into a flat ribbon the AR view
/// can draw.
///
/// A line in SceneKit is one pixel wide and vanishes at arm's length, so the
/// outline is drawn as a strip of triangles instead: two vertices at every
/// point of the ring, one either side of it, in the plane of the face. The
/// native side hands the strip straight to the renderer; all the geometry is
/// here, where it can be tested.
class OutlineRibbon {
  const OutlineRibbon._();

  /// Vertices of a closed triangle strip, as a flat `x y z` buffer.
  ///
  /// [ring] is the outline in world space, in order round the face; [normal]
  /// is the face's normal, which fixes the direction "either side" means; and
  /// [halfWidth] is how far each edge of the ribbon sits from the ring, in
  /// metres.
  ///
  /// The strip has `2 * (ring.length + 1)` vertices: the last pair repeats the
  /// first, closing the loop.
  static Float32List strip(
    List<Vector3> ring,
    Vector3 normal,
    double halfWidth,
  ) {
    final n = ring.length;
    if (n < 3) return Float32List(0);

    final up = normal.normalized();
    final out = Float32List(6 * (n + 1));

    for (var i = 0; i <= n; i++) {
      final k = i % n;

      final before = ring[(k - 1 + n) % n];
      final after = ring[(k + 1) % n];

      // Along the ring here; across it, in the plane of the face, is the
      // direction to step to either side.
      final along = after - before;
      var across = up.cross(along);

      if (across.length2 < 1e-12) {
        across = Vector3.zero();
      } else {
        across.normalize();
      }

      final inner = ring[k] - across * halfWidth;
      final outer = ring[k] + across * halfWidth;

      final base = 6 * i;
      out[base] = inner.x;
      out[base + 1] = inner.y;
      out[base + 2] = inner.z;
      out[base + 3] = outer.x;
      out[base + 4] = outer.y;
      out[base + 5] = outer.z;
    }

    return out;
  }

  /// A width that reads at the range the user is standing: about 5 mm of
  /// half-width per metre, never thinner than 3 mm.
  static double halfWidthFor(double distanceMetres) {
    final width = 0.005 * (distanceMetres < 0.5 ? 0.5 : distanceMetres);
    return width < 0.003 ? 0.003 : width;
  }
}
