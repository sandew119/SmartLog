import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'depth_frame.dart';

/// A plane in a depth frame's own camera space.
///
/// Everything in the face finder is worked out here, in the camera's frame,
/// and only the answer is carried into world space. That is not a
/// micro-optimisation: unprojecting a pixel into world space allocates two
/// vectors and does a 4x4 multiply, and a fill visits thousands of pixels
/// several times a frame. In camera space the distance of a pixel from a plane
/// is one multiply-add on numbers already in hand.
///
/// The plane is `normal . P = offset`. A pixel at depth `d` sits at
/// `P = d * ray`, with `ray = ((x-cx)/fx, -(y-cy)/fy, -1)`, so its signed
/// distance is `d * (normal . ray) - offset`.
class CameraPlane {
  final double nx, ny, nz;
  final double offset;

  const CameraPlane(this.nx, this.ny, this.nz, this.offset);

  /// Signed perpendicular distance of the surface seen at pixel ([x], [y]) at
  /// [depth], in metres.
  double distance(DepthFrame frame, int x, int y, double depth) {
    final k = nx * (x - frame.cx) / frame.fx -
        ny * (y - frame.cy) / frame.fy -
        nz;
    return depth * k - offset;
  }

  /// How much further than the plane the surface at a pixel is, along the
  /// line of sight. Positive means behind the plane, negative in front.
  ///
  /// This, not the perpendicular distance, is what tells an edge that is
  /// smeared across a couple of pixels from one that is sharp: the depth at a
  /// smeared pixel lies between the face's and the background's, and both are
  /// measured the same way, along the ray.
  double alongRay(DepthFrame frame, int x, int y, double depth) {
    final k = nx * (x - frame.cx) / frame.fx -
        ny * (y - frame.cy) / frame.fy -
        nz;
    if (k.abs() < 1e-9) return 0;
    return depth - offset / k;
  }

  static CameraPlane through(Vector3 point, Vector3 normal) {
    final n = normal.normalized();
    return CameraPlane(n.x, n.y, n.z, n.dot(point));
  }
}

/// The result of fitting a plane to pixels: the plane, the spread about it,
/// and where the pixels' centroid is (in camera space).
class PlaneEstimate {
  final CameraPlane plane;
  final double rmsMetres;
  final Vector3 centroid;
  final int count;

  const PlaneEstimate({
    required this.plane,
    required this.rmsMetres,
    required this.centroid,
    required this.count,
  });
}

/// A single connected patch of pixels that lie on one plane.
class PlaneRegion {
  /// Pixel indices (`y * width + x`), in the order they were reached.
  final List<int> pixels;

  final bool touchesEdge;
  final bool spansOppositeEdges;

  const PlaneRegion({
    required this.pixels,
    required this.touchesEdge,
    required this.spansOppositeEdges,
  });
}

/// The plane-first machinery behind cut-face detection.
///
/// **Why plane first.** The face finder used to grow a region from the seed
/// while the depth stayed continuous, and only afterwards ask whether the
/// result was flat. On a log lying on the ground that order fails every time:
/// depth is continuous from the cut face straight down onto the ground, the
/// fill follows it, the resulting L-shape is not flat, and the scan is
/// refused -- from every angle, at every distance. Two logs in contact have
/// the same problem in the sideways direction.
///
/// Asking the flatness question *while* growing removes the failure. A pixel
/// joins only if it lies on the plane fitted to the patch around the seed, so
/// the ground -- which crosses that plane at a right angle -- contributes a
/// sliver a couple of pixels deep instead of an entire floor.
class FaceSegmentation {
  const FaceSegmentation._();

  /// Sensor noise assumed at a range, in metres (one standard deviation).
  ///
  /// A prior, not a measurement: it stops a very quiet patch from producing a
  /// tolerance tighter than the sensor can honour. The tolerances that
  /// actually decide a scan come from the patch's own measured spread.
  static double noiseFloor(double depthMetres) =>
      0.0025 + 0.004 * depthMetres;

  /// Bounds on how far from the plane a pixel may sit and still be face.
  static const double minToleranceMetres = 0.008;
  static const double maxToleranceMetres = 0.030;

  /// Half-widths of the seed patch to try, largest first, as physical sizes so
  /// each covers the same stretch of log at any range.
  ///
  /// The bigger the patch the better its normal -- the error in a fitted
  /// plane's tilt is the sensor noise over the patch's width -- and a good
  /// first normal is most of what a fast, stable fill needs. But a big patch
  /// only fits a big face, so the smaller ones are the fallback for a small
  /// end, or an aim that is off-centre.
  static const List<double> seedPatchMetres = [0.05, 0.03, 0.016];

  /// A patch must have this share of its pixels readable to be trusted.
  static const double minPatchCoverage = 0.5;

  /// How far a face is allowed to extend from the seed, in metres. Bounds the
  /// fill on a wall or a stack front that never ends: no log end is a metre and
  /// a half across, and every pixel past this is work spent on a surface that
  /// cannot be what the user is measuring.
  static const double maxReachMetres = 0.75;

  /// Tolerance from a measured spread and a range.
  static double toleranceFor(double rmsMetres, double depthMetres,
      {double factor = 3.5}) {
    final basis = math.max(rmsMetres, 0.6 * noiseFloor(depthMetres));
    return (factor * basis).clamp(minToleranceMetres, maxToleranceMetres);
  }

  // --- Seed plane ----------------------------------------------------------

  /// Fits a plane to the small patch of surface around a seed pixel.
  ///
  /// Returns null when the patch is not readable or is not planar -- the seed
  /// is on a crack, an edge, or curved bark, and the caller should try
  /// somewhere else.
  static PlaneEstimate? seedPlane(DepthFrame frame, int sx, int sy) {
    final centreDepth = frame.medianDepthAround(sx, sy);
    if (centreDepth == null) return null;

    for (final patch in seedPatchMetres) {
      final fit = _patchPlane(frame, sx, sy, centreDepth, patch);
      if (fit != null) return fit;
    }

    return null;
  }

  static PlaneEstimate? _patchPlane(
    DepthFrame frame,
    int sx,
    int sy,
    double centreDepth,
    double patchMetres,
  ) {
    final radius =
        (patchMetres * frame.fx / centreDepth).round().clamp(2, 9).toInt();

    // Surface within this of the centre reading is the seed's own: a patch
    // that straddles an edge would otherwise fit a plane through the gap. The
    // window widens with the patch, because a face leaning away at 60 degrees
    // drops back by nearly twice its own half-width.
    final window = 0.03 + 2 * patchMetres;

    final xs = <double>[];
    final ys = <double>[];
    final zs = <double>[];

    var total = 0;

    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        // A disc, not a square: the corners are the part likeliest to be off
        // the face.
        if (dx * dx + dy * dy > radius * radius) continue;
        total++;

        final x = sx + dx;
        final y = sy + dy;
        final depth = frame.depthAt(x, y);
        if (depth == null) continue;

        if ((depth - centreDepth).abs() > window) continue;

        xs.add((x - frame.cx) * depth / frame.fx);
        ys.add(-(y - frame.cy) * depth / frame.fy);
        zs.add(-depth);
      }
    }

    if (xs.length < 9 || xs.length < total * minPatchCoverage) return null;

    var fit = _fit(xs, ys, zs, null);
    if (fit == null) return null;

    // Two rounds of trimming, so a stray flying pixel in the patch does not
    // tilt the plane the whole fill is then confined to.
    for (var round = 0; round < 2; round++) {
      final limit = math.max(2.5 * fit!.rmsMetres, 0.004);
      final keep = List<bool>.filled(xs.length, false);
      var kept = 0;

      for (var i = 0; i < xs.length; i++) {
        final d = _pointDistance(fit.plane, xs[i], ys[i], zs[i]).abs();
        if (d <= limit) {
          keep[i] = true;
          kept++;
        }
      }

      if (kept < 9 || kept == xs.length) break;

      final trimmed = _fit(xs, ys, zs, keep);
      if (trimmed == null) break;
      fit = trimmed;
    }

    // A patch that is not planar is not on a cut face.
    final allowed = math.max(0.008, 2.5 * noiseFloor(centreDepth));
    if (fit!.rmsMetres > allowed) return null;

    // The share of the patch the fit accounts for. A big patch that is half
    // face and half something else fits neither.
    var inside = 0;
    for (var i = 0; i < xs.length; i++) {
      if (_pointDistance(fit.plane, xs[i], ys[i], zs[i]).abs() <=
          math.max(3 * fit.rmsMetres, 0.006)) {
        inside++;
      }
    }

    if (inside < xs.length * 0.8) return null;

    return fit;
  }

  // --- Growth --------------------------------------------------------------

  /// Grows a region from [seedX], [seedY] over every connected pixel within
  /// [tolerance] of [plane].
  static PlaneRegion growOnPlane(
    DepthFrame frame,
    int seedX,
    int seedY,
    CameraPlane plane,
    double tolerance, {
    double seedDepth = 1,
  }) {
    final width = frame.width;
    final height = frame.height;
    final total = width * height;

    final reachPixels =
        (maxReachMetres * frame.fx / math.max(seedDepth, 0.2)).ceil();
    final reachSquared = reachPixels * reachPixels;

    final visited = Uint8List(total);
    final queue = Int32List(total);

    var head = 0;
    var tail = 0;

    var touchesLeft = false;
    var touchesRight = false;
    var touchesTop = false;
    var touchesBottom = false;

    final pixels = <int>[];

    final seedIndex = seedY * width + seedX;
    visited[seedIndex] = 1;
    queue[tail++] = seedIndex;

    while (head < tail) {
      final index = queue[head++];
      final x = index % width;
      final y = index ~/ width;

      final depth = frame.depthAt(x, y);
      if (depth == null) continue;

      if (plane.distance(frame, x, y, depth).abs() > tolerance) continue;

      pixels.add(index);

      if (x == 0) touchesLeft = true;
      if (x == width - 1) touchesRight = true;
      if (y == 0) touchesTop = true;
      if (y == height - 1) touchesBottom = true;

      for (var side = 0; side < 4; side++) {
        final nx = x + (side == 0 ? 1 : (side == 1 ? -1 : 0));
        final ny = y + (side == 2 ? 1 : (side == 3 ? -1 : 0));

        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;

        final neighbour = ny * width + nx;
        if (visited[neighbour] != 0) continue;

        final ddx = nx - seedX;
        final ddy = ny - seedY;
        if (ddx * ddx + ddy * ddy > reachSquared) continue;

        visited[neighbour] = 1;
        queue[tail++] = neighbour;
      }
    }

    return PlaneRegion(
      pixels: pixels,
      touchesEdge: touchesLeft || touchesRight || touchesTop || touchesBottom,
      spansOppositeEdges:
          (touchesLeft && touchesRight) || (touchesTop && touchesBottom),
    );
  }

  /// Removes region pixels that sit on the plane only by crossing it.
  ///
  /// Where a log lies on the ground the earth meets the face's plane at a right
  /// angle, and for a few pixels either side of that line it is within
  /// tolerance: a thin strip, attached to the face all the way along its base.
  /// Nothing in a single pixel's own depth says it is ground -- but its
  /// neighbourhood does. The neighbours of a face pixel that are part of the
  /// same surface (within a few centimetres in depth) are nearly all on the
  /// plane; the neighbours of a ground pixel run off it in one direction, and
  /// most are not.
  ///
  /// Neighbours in a different surface altogether -- the wall behind, a face
  /// further along -- are ignored rather than counted against, so the rim of a
  /// face against a distant background is untouched. Only a surface that
  /// continues from the pixel and leaves the plane is evidence.
  static List<int> pruneOffPlaneNeighbours(
    DepthFrame frame,
    CameraPlane plane,
    double tolerance,
    List<int> pixels, {
    int reach = 3,
    double continuityMetres = 0.05,
    double minOnPlane = 0.6,
  }) {
    if (pixels.length < 60) return pixels;

    final width = frame.width;
    final height = frame.height;

    // A pixel with the whole of its window inside the region has every
    // neighbour on the plane by construction, so it cannot fail. An integral
    // image of the region says which those are in constant time, which leaves
    // only the pixels near the rim to be looked at -- the great majority of a
    // large region is deep inside it.
    final stride = width + 1;
    final integral = Int32List(stride * (height + 1));

    final inRegion = Uint8List(width * height);
    for (final index in pixels) {
      inRegion[index] = 1;
    }

    for (var y = 0; y < height; y++) {
      var row = 0;
      for (var x = 0; x < width; x++) {
        row += inRegion[y * width + x];
        integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row;
      }
    }

    final window = (2 * reach + 1) * (2 * reach + 1);

    final kept = <int>[];

    for (final index in pixels) {
      final x = index % width;
      final y = index ~/ width;

      if (x >= reach && y >= reach && x < width - reach && y < height - reach) {
        final full = integral[(y + reach + 1) * stride + x + reach + 1] -
            integral[(y - reach) * stride + x + reach + 1] -
            integral[(y + reach + 1) * stride + x - reach] +
            integral[(y - reach) * stride + x - reach];

        if (full == window) {
          kept.add(index);
          continue;
        }
      }

      final depth = frame.depthAt(x, y);
      if (depth == null) {
        kept.add(index);
        continue;
      }

      var continuous = 0;
      var onPlane = 0;

      for (var dy = -reach; dy <= reach; dy++) {
        final ny = y + dy;
        if (ny < 0 || ny >= height) continue;

        for (var dx = -reach; dx <= reach; dx++) {
          final nx = x + dx;
          if (nx < 0 || nx >= width) continue;

          final neighbour = frame.depthAt(nx, ny);
          if (neighbour == null) continue;

          if ((neighbour - depth).abs() > continuityMetres) continue;

          continuous++;
          if (plane.distance(frame, nx, ny, neighbour).abs() <= tolerance) {
            onPlane++;
          }
        }
      }

      if (continuous < 8 || onPlane >= minOnPlane * continuous) {
        kept.add(index);
      }
    }

    return kept;
  }

  /// Fits a plane to a region's pixels, trimming the worst so that a smeared
  /// edge pixel or two cannot pull the normal round.
  static PlaneEstimate? fitRegion(DepthFrame frame, List<int> pixels) {
    if (pixels.length < 12) return null;

    final xs = <double>[];
    final ys = <double>[];
    final zs = <double>[];

    // Only the interior. The rim of a region is where the fill is least
    // certain -- smeared edge pixels, the sliver of ground where a log meets
    // the earth -- and a strip a few pixels wide and a metre long can tilt a
    // plane fitted through it almost at will. The body of the face is a few
    // pixels in from any edge.
    final basis = interior(pixels, frame.width, frame.height);

    for (final index in basis) {
      final x = index % frame.width;
      final y = index ~/ frame.width;
      final depth = frame.depthAt(x, y);
      if (depth == null) continue;

      xs.add((x - frame.cx) * depth / frame.fx);
      ys.add(-(y - frame.cy) * depth / frame.fy);
      zs.add(-depth);
    }

    var fit = _fit(xs, ys, zs, null);
    if (fit == null) return null;

    final limit = math.max(2.0 * fit.rmsMetres, 0.005);
    final keep = List<bool>.filled(xs.length, false);
    var kept = 0;

    for (var i = 0; i < xs.length; i++) {
      if (_pointDistance(fit.plane, xs[i], ys[i], zs[i]).abs() <= limit) {
        keep[i] = true;
        kept++;
      }
    }

    if (kept >= 12 && kept < xs.length) {
      final trimmed = _fit(xs, ys, zs, keep);
      if (trimmed != null) fit = trimmed;
    }

    return fit;
  }

  /// The pixels of a region at least [minDistance] from its edge, or the whole
  /// region when that would leave too few to fit anything.
  static List<int> interior(
    List<int> pixels,
    int width,
    int height, {
    double minDistance = 2.5,
  }) {
    if (pixels.length < 60) return pixels;

    var minX = width, minY = height, maxX = 0, maxY = 0;

    for (final index in pixels) {
      final x = index % width;
      final y = index ~/ width;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    final w = maxX - minX + 3;
    final h = maxY - minY + 3;

    final mask = Uint8List(w * h);
    for (final index in pixels) {
      mask[(index ~/ width - minY + 1) * w + (index % width - minX + 1)] = 1;
    }

    final distance = _distanceTransform(mask, w, h);

    final kept = <int>[];
    for (final index in pixels) {
      final d =
          distance[(index ~/ width - minY + 1) * w + (index % width - minX + 1)];
      if (d >= minDistance) kept.add(index);
    }

    return kept.length >= 30 ? kept : pixels;
  }

  static double _pointDistance(
          CameraPlane plane, double x, double y, double z) =>
      plane.nx * x + plane.ny * y + plane.nz * z - plane.offset;

  /// Principal-component plane fit over camera-space coordinates, optionally
  /// restricted to [keep]. The normal is the direction of least variance,
  /// found by power iteration on `trace*I - C`, as [PlaneFit] does.
  static PlaneEstimate? _fit(
    List<double> xs,
    List<double> ys,
    List<double> zs,
    List<bool>? keep,
  ) {
    var n = 0;
    var mx = 0.0, my = 0.0, mz = 0.0;

    for (var i = 0; i < xs.length; i++) {
      if (keep != null && !keep[i]) continue;
      mx += xs[i];
      my += ys[i];
      mz += zs[i];
      n++;
    }

    if (n < 6) return null;

    mx /= n;
    my /= n;
    mz /= n;

    var xx = 0.0, xy = 0.0, xz = 0.0, yy = 0.0, yz = 0.0, zz = 0.0;

    for (var i = 0; i < xs.length; i++) {
      if (keep != null && !keep[i]) continue;

      final dx = xs[i] - mx;
      final dy = ys[i] - my;
      final dz = zs[i] - mz;

      xx += dx * dx;
      xy += dx * dy;
      xz += dx * dz;
      yy += dy * dy;
      yz += dy * dz;
      zz += dz * dz;
    }

    final trace = xx + yy + zz;
    if (!trace.isFinite || trace <= 0) return null;

    final a00 = trace - xx, a01 = -xy, a02 = -xz;
    final a11 = trace - yy, a12 = -yz;
    final a22 = trace - zz;

    var vx = 0.5770, vy = 0.5771, vz = 0.5772;

    for (var i = 0; i < 48; i++) {
      final ax = a00 * vx + a01 * vy + a02 * vz;
      final ay = a01 * vx + a11 * vy + a12 * vz;
      final az = a02 * vx + a12 * vy + a22 * vz;

      final magnitude = math.sqrt(ax * ax + ay * ay + az * az);
      if (!magnitude.isFinite || magnitude < 1e-12) return null;

      vx = ax / magnitude;
      vy = ay / magnitude;
      vz = az / magnitude;
    }

    var squared = 0.0;

    for (var i = 0; i < xs.length; i++) {
      if (keep != null && !keep[i]) continue;

      final d = (xs[i] - mx) * vx + (ys[i] - my) * vy + (zs[i] - mz) * vz;
      squared += d * d;
    }

    final rms = math.sqrt(squared / n);
    if (!rms.isFinite) return null;

    return PlaneEstimate(
      plane: CameraPlane(vx, vy, vz, vx * mx + vy * my + vz * mz),
      rmsMetres: rms,
      centroid: Vector3(mx, my, mz),
      count: n,
    );
  }

  // --- Touching faces ------------------------------------------------------

  /// Splits a region of coplanar pixels into one cell per log end, and
  /// returns the pixels of the cell holding [seed].
  ///
  /// Two ends that touch are coplanar and connected, so no depth or plane
  /// test can tell them apart -- they are one region. What separates them is
  /// their shape: each is a fat blob joined to the next through a thin neck.
  /// The distance from the nearest non-region pixel peaks at each log's
  /// centre and dips at the neck, and a watershed on that landscape puts one
  /// cell round each peak.
  ///
  /// A peak is only kept as its own log if it rises well above the neck that
  /// joins it to its neighbour. The ripples on the edge of a single rough
  /// face are far shallower than that and are merged back, so an ordinary
  /// face is never cut in two.
  ///
  /// Returns [pixels] unchanged when there is only one log in it.
  static List<int> cellContaining({
    required List<int> pixels,
    required int seed,
    required int width,
    required int height,
    double openingPixels = 0,
  }) {
    if (pixels.length < 40) return pixels;

    var minX = width, minY = height, maxX = 0, maxY = 0;

    for (final index in pixels) {
      final x = index % width;
      final y = index ~/ width;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    // A one-pixel margin, so the distance transform sees the outside on
    // every side and the hole fill below has somewhere to start.
    final w = maxX - minX + 3;
    final h = maxY - minY + 3;

    final mask = Uint8List(w * h);

    for (final index in pixels) {
      final x = index % width - minX + 1;
      final y = index ~/ width - minY + 1;
      mask[y * w + x] = 1;
    }

    // Holes are NOT filled here. In a packed stack the gap between three
    // touching ends is enclosed, exactly as a knot is, and filling it would
    // weld the ends into one solid block with no boundaries left to find.
    // Holes are filled afterwards, on the one cell that was picked, where an
    // enclosed hole really is a knot.
    _closeGaps(mask, w, h);

    // Sensor noise leaves a scatter of small holes in a face: a pixel or a
    // handful beyond the tolerance. Left in, each one breaks up the eroded core
    // the opening below works from. They are far smaller than the gap between
    // three touching ends, which is a share of a whole face.
    _fillSmallHoles(mask, w, h, math.max(6, (pixels.length * 0.004).round()));

    final seedX = seed % width - minX + 1;
    final seedY = seed ~/ width - minY + 1;

    if (openingPixels > 0) _open(mask, w, h, seedX, seedY, openingPixels);

    final distance = _distanceTransform(mask, w, h);
    final labels = _watershed(mask, distance, w, h);

    var cellMask = mask;

    if (labels != null && labels.count > 1) {
      var target = labels.labels[seedY * w + seedX];

      // A seed on a hole or a gap has no label of its own; borrow the
      // nearest labelled pixel.
      if (target <= 0) {
        var best = double.infinity;

        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final label = labels.labels[y * w + x];
            if (label <= 0) continue;

            final dx = x - seedX;
            final dy = y - seedY;
            final d = (dx * dx + dy * dy).toDouble();

            if (d < best) {
              best = d;
              target = label;
            }
          }
        }
      }

      if (target > 0) {
        cellMask = Uint8List(w * h);
        for (var i = 0; i < cellMask.length; i++) {
          if (labels.labels[i] == target) cellMask[i] = 1;
        }
      }
    }

    _fillHoles(cellMask, w, h);

    final cell = _pixelsOf(cellMask, w, h, minX, minY, width);
    return cell.isEmpty ? pixels : cell;
  }

  static List<int> _pixelsOf(
    Uint8List mask,
    int w,
    int h,
    int minX,
    int minY,
    int width,
  ) {
    final out = <int>[];

    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        if (mask[y * w + x] != 0) {
          out.add((y + minY - 1) * width + (x + minX - 1));
        }
      }
    }

    return out;
  }

  /// Removes anything thinner than about twice [radius] pixels, keeping the
  /// body the seed is in.
  ///
  /// The place a log end meets the ground is the reason this exists. The
  /// ground crosses the face's plane at the base of the face, and for a couple
  /// of pixels either side of that line it lies within the flatness
  /// tolerance -- a strip that runs from the face clear across the frame.
  /// Nothing about it is wrong on the plane test, but it is a strip and the
  /// face is a disc, and an opening (erode, keep the seed's body, grow it back)
  /// removes the one and leaves the other. Skipped for a region too small to
  /// spare the pixels: on a face only a few pixels across, opening would eat
  /// the face itself.
  static void _open(
    Uint8List mask,
    int w,
    int h,
    int seedX,
    int seedY,
    double radius,
  ) {
    final distance = _distanceTransform(mask, w, h);

    var peak = 0.0;
    for (var i = 0; i < distance.length; i++) {
      if (distance[i] > peak) peak = distance[i];
    }

    if (peak < 1.6 * radius) return;

    // The core: everything at least [radius] from the outside.
    final core = Uint8List(w * h);
    for (var i = 0; i < core.length; i++) {
      core[i] = mask[i] != 0 && distance[i] >= radius ? 1 : 0;
    }

    // Label the core's connected pieces.
    final piece = Int32List(w * h);
    final queue = Int32List(w * h);
    final sizes = <int>[0];
    final nearestToSeed = <double>[double.infinity];

    for (var start = 0; start < core.length; start++) {
      if (core[start] == 0 || piece[start] != 0) continue;

      final id = sizes.length;
      sizes.add(0);
      nearestToSeed.add(double.infinity);

      var head = 0, tail = 0;
      piece[start] = id;
      queue[tail++] = start;

      while (head < tail) {
        final i = queue[head++];
        final x = i % w;
        final y = i ~/ w;

        sizes[id]++;

        final dx = x - seedX;
        final dy = y - seedY;
        final d = (dx * dx + dy * dy).toDouble();
        if (d < nearestToSeed[id]) nearestToSeed[id] = d;

        for (var side = 0; side < 4; side++) {
          final nx = x + (side == 0 ? 1 : (side == 1 ? -1 : 0));
          final ny = y + (side == 2 ? 1 : (side == 3 ? -1 : 0));

          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;

          final n = ny * w + nx;
          if (core[n] == 0 || piece[n] != 0) continue;

          piece[n] = id;
          queue[tail++] = n;
        }
      }
    }

    if (sizes.length <= 1) return;

    var largest = 0;
    for (var id = 1; id < sizes.length; id++) {
      if (sizes[id] > largest) largest = sizes[id];
    }

    // The piece nearest the seed -- unless it is a fragment beside a much
    // bigger one, in which case the seed is on a scrap and the body is the
    // big piece.
    var chosen = 0;
    var chosenDistance = double.infinity;

    for (var id = 1; id < sizes.length; id++) {
      if (sizes[id] < 0.25 * largest) continue;

      if (nearestToSeed[id] < chosenDistance) {
        chosenDistance = nearestToSeed[id];
        chosen = id;
      }
    }

    if (chosen == 0) return;

    final body = Uint8List(w * h);
    for (var i = 0; i < body.length; i++) {
      body[i] = piece[i] == chosen ? 1 : 0;
    }

    // Grow the body back by the same radius, within what was there.
    final outside = Uint8List(w * h);
    for (var i = 0; i < outside.length; i++) {
      outside[i] = body[i] == 0 ? 1 : 0;
    }

    final toBody = _distanceTransform(outside, w, h);

    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0) continue;
      mask[i] = (body[i] != 0 || toBody[i] <= radius) ? 1 : 0;
    }
  }

  /// Marks background pixels the outside cannot reach as part of the face:
  /// a knot, a rotten pith, a dropped return in the middle of the end.
  static void _fillHoles(Uint8List mask, int w, int h) {
    final outside = Uint8List(w * h);
    final queue = Int32List(w * h);
    var head = 0, tail = 0;

    void push(int x, int y) {
      final i = y * w + x;
      if (mask[i] != 0 || outside[i] != 0) return;
      outside[i] = 1;
      queue[tail++] = i;
    }

    for (var x = 0; x < w; x++) {
      push(x, 0);
      push(x, h - 1);
    }
    for (var y = 0; y < h; y++) {
      push(0, y);
      push(w - 1, y);
    }

    while (head < tail) {
      final i = queue[head++];
      final x = i % w;
      final y = i ~/ w;

      if (x > 0) push(x - 1, y);
      if (x < w - 1) push(x + 1, y);
      if (y > 0) push(x, y - 1);
      if (y < h - 1) push(x, y + 1);
    }

    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0 && outside[i] == 0) mask[i] = 1;
    }
  }

  /// Fills enclosed holes no bigger than [maxArea] pixels.
  static void _fillSmallHoles(Uint8List mask, int w, int h, int maxArea) {
    final seen = Uint8List(w * h);
    final queue = Int32List(w * h);

    // Background reachable from the border is outside, not a hole.
    var head = 0, tail = 0;

    void push(int x, int y) {
      final i = y * w + x;
      if (mask[i] != 0 || seen[i] != 0) return;
      seen[i] = 1;
      queue[tail++] = i;
    }

    for (var x = 0; x < w; x++) {
      push(x, 0);
      push(x, h - 1);
    }
    for (var y = 0; y < h; y++) {
      push(0, y);
      push(w - 1, y);
    }

    while (head < tail) {
      final i = queue[head++];
      final x = i % w;
      final y = i ~/ w;

      if (x > 0) push(x - 1, y);
      if (x < w - 1) push(x + 1, y);
      if (y > 0) push(x, y - 1);
      if (y < h - 1) push(x, y + 1);
    }

    for (var start = 0; start < mask.length; start++) {
      if (mask[start] != 0 || seen[start] != 0) continue;

      // One enclosed hole: gather it, and fill it if it is small.
      final hole = <int>[];
      var inner = 0;
      hole.add(start);
      seen[start] = 1;

      while (inner < hole.length) {
        final i = hole[inner++];
        final x = i % w;
        final y = i ~/ w;

        for (var side = 0; side < 4; side++) {
          final nx = x + (side == 0 ? 1 : (side == 1 ? -1 : 0));
          final ny = y + (side == 2 ? 1 : (side == 3 ? -1 : 0));

          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;

          final n = ny * w + nx;
          if (mask[n] != 0 || seen[n] != 0) continue;

          seen[n] = 1;
          hole.add(n);
        }
      }

      if (hole.length <= maxArea) {
        for (final i in hole) {
          mask[i] = 1;
        }
      }
    }
  }

  /// Closes one-pixel slits -- a hairline crack, an end check, a column of
  /// dropped returns -- so they cannot split a face in two.
  ///
  /// A background pixel is filled when there is face on both sides of it,
  /// within [reach] pixels, along a row or a column.
  ///
  /// [reach] is 1 on purpose. Wider closing does close wider cracks, but it
  /// also welds the small pockets between three touching ends into the ends
  /// themselves -- which are the only boundaries a packed stack has -- and it
  /// adds a fillet of ground either side of a log end's base. A crack wide
  /// enough to survive this (two pixels or more, so a centimetre or so at
  /// arm's length) that also runs from the rim to the pith can still split a
  /// face into halves; that is a known limit, and a half-face is the one
  /// wrong answer the compactness test does not catch.
  static void _closeGaps(Uint8List mask, int w, int h, {int reach = 1}) {
    final grown = Uint8List.fromList(mask);

    bool face(int x, int y) =>
        x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] != 0;

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] != 0) continue;

        var left = false, right = false, up = false, down = false;

        for (var k = 1; k <= reach; k++) {
          left = left || face(x - k, y);
          right = right || face(x + k, y);
          up = up || face(x, y - k);
          down = down || face(x, y + k);
        }

        if ((left && right) || (up && down)) grown[y * w + x] = 1;
      }
    }

    for (var i = 0; i < mask.length; i++) {
      mask[i] = grown[i];
    }
  }

  /// Exact Euclidean distance from every pixel to the nearest pixel outside
  /// the mask (Felzenszwalb & Huttenlocher's linear-time transform), in
  /// pixels.
  static Float32List _distanceTransform(Uint8List mask, int w, int h) {
    const far = 1e12;

    final squared = Float64List(w * h);
    for (var i = 0; i < squared.length; i++) {
      squared[i] = mask[i] != 0 ? far : 0;
    }

    final longest = math.max(w, h);
    final f = Float64List(longest);
    final v = Int32List(longest);
    final z = Float64List(longest + 1);

    // The lower envelope of the parabolas rooted at each sample, evaluated
    // back at the samples. Works on `f` in place and leaves the result there.
    void envelope(int length) {
      var k = 0;
      v[0] = 0;
      z[0] = double.negativeInfinity;
      z[1] = double.infinity;

      for (var q = 1; q < length; q++) {
        double s;

        while (true) {
          final p = v[k];
          s = ((f[q] + q * q) - (f[p] + p * p)) / (2.0 * q - 2.0 * p);

          if (s <= z[k]) {
            k--;
          } else {
            break;
          }
        }

        k++;
        v[k] = q;
        z[k] = s;
        z[k + 1] = double.infinity;
      }

      k = 0;
      final result = Float64List(length);

      for (var q = 0; q < length; q++) {
        while (z[k + 1] < q) {
          k++;
        }
        final p = v[k];
        result[q] = (q - p) * (q - p) + f[p];
      }

      for (var q = 0; q < length; q++) {
        f[q] = result[q];
      }
    }

    for (var x = 0; x < w; x++) {
      for (var y = 0; y < h; y++) {
        f[y] = squared[y * w + x];
      }
      envelope(h);
      for (var y = 0; y < h; y++) {
        squared[y * w + x] = f[y];
      }
    }

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        f[x] = squared[y * w + x];
      }
      envelope(w);
      for (var x = 0; x < w; x++) {
        squared[y * w + x] = f[x];
      }
    }

    final out = Float32List(w * h);
    for (var i = 0; i < out.length; i++) {
      out[i] = mask[i] == 0 ? 0 : math.sqrt(squared[i]);
    }

    return out;
  }

  /// Watershed on the distance landscape, with peaks merged unless they are
  /// clearly separate.
  ///
  /// Pixels are taken from the highest distance down. One that touches no
  /// labelled pixel starts a new basin; one that touches basins joins the
  /// tallest; and where two basins meet, the lower peak is absorbed if it
  /// stands less than [_minDynamic] above the saddle where they meet.
  static ({Int32List labels, int count})? _watershed(
    Uint8List mask,
    Float32List distance,
    int w,
    int h,
  ) {
    var count = 0;
    var peak = 0.0;

    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0) continue;

      count++;
      if (distance[i] > peak) peak = distance[i];
    }

    if (count < 20) return null;

    // Highest distance first, by counting sort: an eighth of a pixel is finer
    // than anything the distance means here, and a comparator sort of every
    // pixel in a big region is where most of the time was going.
    const resolution = 8;
    final buckets = (peak * resolution).ceil() + 2;
    final tally = Int32List(buckets + 1);

    int keyOf(int i) => buckets - (distance[i] * resolution).round();

    for (var i = 0; i < mask.length; i++) {
      if (mask[i] != 0) tally[keyOf(i) + 1]++;
    }

    for (var k = 1; k <= buckets; k++) {
      tally[k] += tally[k - 1];
    }

    final order = Int32List(count);

    for (var i = 0; i < mask.length; i++) {
      if (mask[i] != 0) order[tally[keyOf(i)]++] = i;
    }

    final labels = Int32List(w * h);

    // Union-find over basin labels, with each root's peak height.
    final parent = <int>[0];
    final heights = <double>[0];

    int find(int a) {
      while (parent[a] != a) {
        parent[a] = parent[parent[a]];
        a = parent[a];
      }
      return a;
    }

    final roots = <int>[];

    for (final index in order) {
      final x = index % w;
      final y = index ~/ w;
      final here = distance[index].toDouble();

      roots.clear();

      // The neighbour on the steepest way up -- the basin this pixel drains
      // to. Joining "the tallest peak in reach" instead lets one basin creep
      // along the rim of another wherever two peaks tie, which for two
      // equal-sized ends is always.
      var bestLabel = 0;
      var bestHeight = -1.0;

      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;

          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;

          final n = ny * w + nx;
          final label = labels[n];
          if (label <= 0) continue;

          final root = find(label);
          if (!roots.contains(root)) roots.add(root);

          if (distance[n] > bestHeight) {
            bestHeight = distance[n];
            bestLabel = root;
          }
        }
      }

      if (roots.isEmpty) {
        final id = parent.length;
        parent.add(id);
        heights.add(here);
        labels[index] = id;
        continue;
      }

      var tallest = roots.first;
      for (final r in roots) {
        if (heights[r] > heights[tallest]) tallest = r;
      }

      // Merge every neighbouring basin whose peak does not stand clear of
      // this saddle. The rest stay their own logs.
      for (final r in roots) {
        if (r == tallest) continue;

        if (heights[r] - here < _dynamicFor(heights[r])) {
          parent[r] = tallest;
        }
      }

      labels[index] = find(bestLabel);
    }

    final remap = <int, int>{};
    var next = 1;

    for (var i = 0; i < labels.length; i++) {
      if (labels[i] <= 0) continue;

      final root = find(labels[i]);
      labels[i] = remap.putIfAbsent(root, () => next++);
    }

    return (labels: labels, count: next - 1);
  }

  /// How far a peak must stand above the saddle joining it to a bigger one to
  /// count as a separate log: a share of its own height, and never less than
  /// a couple of pixels, which is more than any single rough edge produces.
  static double _dynamicFor(double peakHeight) =>
      math.max(2.0, 0.35 * peakHeight);
}
