import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'depth_frame.dart';
import 'face_segmentation.dart';

/// The outline of a log's cut face, traced through the points the sensor
/// actually returned.
///
/// Held as a radius per angular bin about the face's centre -- a star-shaped
/// description, which is all a log end ever needs and which no circle fit
/// can match on a section that is oval, lobed or flat on one side. A tape
/// laid round the face reads this outline, not a circle through it.
class FaceOutline {
  /// Radius per bin, metres, measured from [centre] in the plane of the
  /// face. Bin `i` spans angles `i * binWidth` to `(i + 1) * binWidth`,
  /// measured from [u] towards [v].
  final List<double> radii;

  /// The traced circumference: the girth of the face.
  final double perimeterMetres;

  /// Area enclosed by the outline.
  final double areaMetres2;

  /// Share of the bins that held real points. The rest were completed by
  /// interpolation, so this is how much of the girth was seen rather than
  /// inferred.
  final double observedFraction;

  /// In-plane basis the angles are measured in, in world space.
  final Vector3 u;
  final Vector3 v;

  const FaceOutline({
    required this.radii,
    required this.perimeterMetres,
    required this.areaMetres2,
    required this.observedFraction,
    required this.u,
    required this.v,
  });

  int get binCount => radii.length;

  double get binWidth => 2 * math.pi / radii.length;

  /// The same outline, uniformly scaled by [factor] about its centre.
  FaceOutline scaled(double factor) => FaceOutline(
        radii: [for (final r in radii) r * factor],
        perimeterMetres: perimeterMetres * factor,
        areaMetres2: areaMetres2 * factor * factor,
        observedFraction: observedFraction,
        u: u,
        v: v,
      );

  /// The radius at an arbitrary angle, interpolated between bin centres.
  double radiusAt(double angleRadians) {
    final n = radii.length;
    if (n == 0) return 0;

    // Bin i is centred half a bin past its start.
    var position = angleRadians / binWidth - 0.5;
    position = position % n;
    if (position < 0) position += n;

    final low = position.floor();
    final fraction = position - low;

    final a = radii[low % n];
    final b = radii[(low + 1) % n];

    return a + (b - a) * fraction;
  }

  /// The width of the face across a direction, as callipers read it: the
  /// gap between the two parallel lines that just touch the outline.
  ///
  /// Deliberately not "the radius one way plus the radius opposite". On
  /// anything but a circle those are different quantities -- the radial pair
  /// is a chord through the centre, and callipers close on the tangents, not
  /// on the chord. Only the tangent version obeys Cauchy's formula, and
  /// Cauchy is the whole mechanism by which a girth measured at the end face
  /// travels down the trunk to sections that can only ever be seen from one
  /// side.
  double widthAtAngle(double angleRadians) {
    final n = radii.length;
    if (n == 0) return 0;

    final nx = math.cos(angleRadians);
    final ny = math.sin(angleRadians);

    var lowest = double.infinity;
    var highest = -double.infinity;

    for (var i = 0; i < n; i++) {
      final a = (i + 0.5) * binWidth;
      final projection = radii[i] * (math.cos(a) * nx + math.sin(a) * ny);

      if (projection < lowest) lowest = projection;
      if (projection > highest) highest = projection;
    }

    final width = highest - lowest;
    return width.isFinite && width > 0 ? width : 0;
  }

  /// The same, for a direction given in world space. The direction is
  /// flattened into the face's own plane first, so a viewing direction that
  /// is not quite square still resolves to the right calliper.
  double? widthAcross(Vector3 worldDirection) {
    final x = worldDirection.dot(u);
    final y = worldDirection.dot(v);

    if (x.abs() < 1e-9 && y.abs() < 1e-9) return null;

    return widthAtAngle(math.atan2(y, x));
  }

  /// Mean calliper width over every direction.
  ///
  /// This is the figure Cauchy's formula is written in: for any convex
  /// outline the perimeter is exactly pi times the mean width. That identity
  /// is what lets a girth be recovered along the trunk, where only one
  /// direction can ever be measured at a time -- see [LogGirthModel].
  double get meanWidthMetres => _widthStats().mean;

  /// The narrowest way across the face -- the reading a caliper finds when
  /// it is turned to the tightest grip it can take.
  double get minWidthMetres => _widthStats().min;

  double get maxWidthMetres => _widthStats().max;

  /// Widths sampled over half a turn, which covers every distinct direction:
  /// a caliper reads the same across a direction and its opposite.
  ({double mean, double min, double max}) _widthStats() {
    final n = radii.length;
    if (n < 2) return (mean: 0, min: 0, max: 0);

    var total = 0.0;
    var lowest = double.infinity;
    var highest = 0.0;

    for (var i = 0; i < n; i++) {
      final width = widthAtAngle(math.pi * i / n);

      total += width;
      lowest = math.min(lowest, width);
      highest = math.max(highest, width);
    }

    return (
      mean: total / n,
      min: lowest.isFinite ? lowest : 0,
      max: highest,
    );
  }

  /// How nearly circular the outline is: 1.0 for a circle, lower for
  /// anything pinched, lobed or made of two logs at once.
  ///
  /// Two log ends touching in a stack trace as one peanut-shaped outline,
  /// and a peanut is the one shape that can pass every other test -- it is
  /// flat, square on, fully in frame, and completely traced -- while
  /// reporting nearly twice the girth of the log the user meant. This is
  /// what catches it.
  double get compactness {
    if (perimeterMetres <= 0) return 0;

    return 4 * math.pi * areaMetres2 / (perimeterMetres * perimeterMetres);
  }

  /// The diameter of a circle with the same area -- the honest single number
  /// for a section that is not round.
  double get equivalentDiameterMetres =>
      areaMetres2 <= 0 ? 0 : 2 * math.sqrt(areaMetres2 / math.pi);

  /// How far from round the face is: 1.0 for a circle, higher for a lobed
  /// or flattened section.
  ///
  /// This is the number that carries the face's shape out along the trunk.
  double get roundness {
    final mean = meanWidthMetres;
    if (mean <= 0) return 1;

    return perimeterMetres / (math.pi * mean);
  }
}

/// A cut face the scanner has resolved from one depth frame.
class FaceScan {
  /// Centre of the face, in world space.
  final Vector3 centre;

  /// Unit normal, pointing back towards the camera. Along a log this is the
  /// direction of the trunk, which is what makes the length walk possible
  /// without the user having to aim at anything.
  final Vector3 normal;

  /// Distance from camera to face centre.
  final double distanceMetres;

  /// Angle between the normal and the line of sight. Zero is square on.
  final double tiltDegrees;

  /// Root-mean-square roughness about the fitted plane, in millimetres. A
  /// sawn end is a few millimetres; the curved side of a trunk is tens.
  final double flatnessMm;

  final int pointCount;

  final FaceOutline outline;

  /// Whether the face runs off the edge of the depth frame -- in which case
  /// part of its girth was never in view and the user must back away.
  final bool touchesFrameEdge;

  /// Steepest curvature of the face's surface, in 1/metres. A sawn end is near
  /// zero; the side of a trunk is several. Kept for the diagnostics report.
  final double curvaturePerMetre;

  const FaceScan({
    required this.centre,
    required this.normal,
    required this.distanceMetres,
    required this.tiltDegrees,
    required this.flatnessMm,
    required this.pointCount,
    required this.outline,
    required this.touchesFrameEdge,
    this.curvaturePerMetre = 0,
  });

  /// The girth of the face: what a tape round the cut end reads.
  double get girthMetres => outline.perimeterMetres;

  /// The traced outline as points in world space, for drawing it on the log.
  ///
  /// [samples] points at equal angles about the centre, each at the outline's
  /// radius there, in the plane of the face.
  List<Vector3> outlinePoints({int samples = 64}) {
    return [
      for (var i = 0; i < samples; i++)
        () {
          final angle = 2 * math.pi * i / samples;
          final r = outline.radiusAt(angle);

          return centre +
              outline.u * (r * math.cos(angle)) +
              outline.v * (r * math.sin(angle));
        }(),
    ];
  }

  double get diameterMetres => outline.equivalentDiameterMetres;
}

/// Why a frame did not yield a face, in the terms the user can act on.
enum FaceRejection {
  noDepth,
  tooClose,
  tooFar,
  tooSmall,
  runsOffScreen,
  notFlat,
  tooAngled,
  outlineIncomplete,
  moreThanOneLog,
  pointingAtTheSide,
}

/// A single frame's attempt at finding a cut face: the face, or the reason
/// there wasn't one.
class FaceAttempt {
  final FaceScan? face;
  final FaceRejection? rejection;

  /// Present even on most rejections, so the guidance can say "you are too
  /// far" rather than only "no face".
  final double? distanceMetres;

  /// Which check refused the frame and by how much, for the diagnostics
  /// report -- "curvature 1.9" says far more than `notFlat` does. Not shown
  /// to the user.
  final String? detail;

  const FaceAttempt.found(FaceScan this.face)
      : rejection = null,
        distanceMetres = null,
        detail = null;

  const FaceAttempt.rejected(this.rejection, {this.distanceMetres, this.detail})
      : face = null;

  bool get isFound => face != null;
}

/// Finds the flat cut end of a log in a depth frame.
///
/// The method is plane first, and it is deliberately not a circle fit. It
/// fits a plane to the few centimetres of surface under the aim point, then
/// grows outwards over every connected pixel that lies on that plane, refitting
/// as the region grows. What stops the growth is the edge of the plane -- so
/// it stops at the rim of a face resting on the ground, where depth carries
/// on continuously into the earth, and it works on a face that is oval,
/// rough, chainsawn at an angle, or pressed against other logs.
///
/// An earlier version grew while depth stayed continuous and judged flatness
/// afterwards. That could not find a log end lying on the ground from any
/// angle, and it measured a whole hexagonal stack of seven ends as one face
/// three times the girth -- both found by rendering those scenes through a
/// noisy sensor model. See `test/face_yard_test.dart`.
///
/// Nothing here needs a tap. The user points, and the middle of the frame is
/// the answer.
class FaceScanner {
  const FaceScanner._();

  /// Angular bins the outline is traced in. One every 7.5 degrees: fine
  /// enough to follow the lobes and flats of a real log end, coarse enough
  /// that each bin still collects several returns.
  static const int outlineBins = 48;

  /// Two neighbouring pixels belong to the same surface while their depths
  /// agree to within this. Used by [growRegion], which the trunk profiler
  /// still relies on.
  static const double stepToleranceMetres = 0.025;

  /// How far in depth [growRegion] may wander from its seed.
  static const double depthSpreadMetres = 0.50;

  /// Working range. Closer than this the sensor is in its blind zone and the
  /// face overflows the frame; further away the returns thin out until an
  /// outline cannot be traced.
  static const double minRangeMetres = 0.25;
  static const double maxRangeMetres = 2.5;

  /// Below this the region is too small to trace an outline at all.
  static const int minRegionPixels = 40;

  /// Above this the region is a wall, a container side or the ground filling
  /// the view, and there is no point working out its outline. The default
  /// 128 x 96 depth grid holds 12,288 pixels in all, so this only ever applies
  /// at full resolution, where an end that big is not one the user can be
  /// asking about and the work grows with the square of the pixel count.
  static const int maxRegionPixels = 20000;

  /// The smallest end reported, as the diameter of the circle with the same
  /// area: 4 cm, a girth of about 5 inches. Below that the sensor's own pixel
  /// grid is a large share of the answer.
  static const double minDiameterMetres = 0.04;

  /// The roughest a cut face may be about its own plane. A sawn end is a few
  /// millimetres out of plane and a badly chainsawn one perhaps fifteen.
  static const double maxFlatnessMm = 25;

  /// The most a cut face may curve, in 1/metres, before it is taken to be the
  /// side of a trunk.
  ///
  /// A quadric is fitted to how far the face's pixels sit from its plane, and
  /// its steepest curvature read off. The side of a log is a cylinder of
  /// radius 0.15-0.5 m, so it curves at 2-7 per metre wherever it is seen; a
  /// sawn end is flat, and even one that has dished as it dried -- a few
  /// millimetres over its diameter -- comes out well under one. Nothing about
  /// this depends on how big the object is, which is why it replaces judging
  /// flatness by a millimetre limit that a small face could never meet.
  ///
  /// This is a floor. On a flat face the fitted curvature is nothing but
  /// sensor noise, and it follows a law that held to within a few percent from
  /// a 4 cm face to a 25 cm one in noisy synthetic scenes:
  ///
  ///     curvature ~ [noiseCurvatureFactor] x depth noise / face radius^2
  ///
  /// so the limit rises with it, and a face too small to judge is accepted
  /// rather than refused for the sensor's own noise.
  static const double maxCurvaturePerMetre = 1.8;
  static const double noiseCurvatureFactor = 1.7;

  /// How many times the expected noise curvature the limit allows.
  static const double noiseCurvatureMargin = 4.0;

  /// Longer than this, relative to its own narrow way across, and what has
  /// been found is a band of trunk lying across the view, not an end.
  static const double maxElongation = 2.4;

  /// A face cropped by the frame reads at the frame's own aspect, near 1.33.
  /// This sits above that, so a cropped end is told to step back while a
  /// band of trunk is told to aim at the end.
  static const double frameShapeAllowance = 1.6;

  /// Beyond this the user is looking along the log rather than at its end.
  /// A vertical end seen from a phone held at chest height, a metre away, is
  /// already at 50 degrees, so the limit has to allow it.
  static const double maxTiltDegrees = 62;

  /// Share of the outline that must come from real returns rather than be
  /// filled in between them.
  static const double minObservedFraction = 0.80;

  /// How nearly circular an outline must be to be one log end. A circle is
  /// 1.0, an oval end about 0.97, a badly lobed one 0.93, and even a split
  /// half-round 0.75. Touching ends are now separated before this is asked,
  /// so what reaches it is a shape the separation could not resolve.
  static const double minCompactness = 0.68;

  /// Tries to resolve a cut face from one frame.
  ///
  /// [seedX]/[seedY] default to the middle of the frame, which is where the
  /// reticle is. If the seed itself is the problem -- on a crack, on a
  /// dropped return, on the seam between two logs -- a few nearby seeds are
  /// tried before giving up, so that an aim that is a few centimetres off
  /// does not mean starting again.
  static FaceAttempt detect(
    DepthFrame frame, {
    int? seedX,
    int? seedY,
    int bins = outlineBins,
  }) {
    final sx = seedX ?? frame.width ~/ 2;
    final sy = seedY ?? frame.height ~/ 2;

    final first = _detectFrom(frame, sx, sy, bins);
    if (first.attempt.isFound || !first.seedTrouble) return first.attempt;

    final depth = frame.medianDepthAround(sx, sy) ?? 0.8;
    final step = (0.03 * frame.fx / depth).round().clamp(3, 9).toInt();

    for (final ring in const [1, 2]) {
      for (var k = 0; k < 8; k++) {
        final angle = k * math.pi / 4;

        final x = sx + (math.cos(angle) * step * ring).round();
        final y = sy + (math.sin(angle) * step * ring).round();

        if (x < 0 || y < 0 || x >= frame.width || y >= frame.height) continue;

        final next = _detectFrom(frame, x, y, bins);
        if (next.attempt.isFound) return next.attempt;
      }
    }

    return first.attempt;
  }

  static ({FaceAttempt attempt, bool seedTrouble}) _detectFrom(
    DepthFrame frame,
    int sx,
    int sy,
    int bins,
  ) {
    ({FaceAttempt attempt, bool seedTrouble}) reject(
      FaceRejection why, {
      double? distance,
      bool seedTrouble = false,
      String? detail,
    }) =>
        (
          attempt: FaceAttempt.rejected(
            why,
            distanceMetres: distance,
            detail: detail,
          ),
          seedTrouble: seedTrouble,
        );

    final seedDepth = frame.medianDepthAround(sx, sy);
    if (seedDepth == null) {
      return reject(FaceRejection.noDepth, seedTrouble: true);
    }

    if (seedDepth < minRangeMetres) {
      return reject(FaceRejection.tooClose, distance: seedDepth);
    }

    if (seedDepth > maxRangeMetres) {
      return reject(FaceRejection.tooFar, distance: seedDepth);
    }

    final seed = FaceSegmentation.seedPlane(frame, sx, sy);
    if (seed == null) {
      return reject(
        FaceRejection.notFlat,
        distance: seedDepth,
        seedTrouble: true,
        detail: 'seed patch not planar',
      );
    }

    // The fill needs a start pixel that has a reading of its own.
    final start = _nearestReadable(frame, sx, sy);
    if (start == null) {
      return reject(FaceRejection.noDepth, seedTrouble: true);
    }

    // Grow, refit on what was found, grow again. The plane from a patch a few
    // centimetres across can be several degrees out; fitted to the whole face
    // it is accurate. The early passes are loose, so that a plane which is
    // still a little out does not clip the face to a narrowing band, and the
    // last is tight, so the edge is decided by the face and not the slack.
    var plane = seed.plane;
    var tolerance =
        FaceSegmentation.toleranceFor(seed.rmsMetres, seedDepth, factor: 5.5);

    PlaneRegion region = FaceSegmentation.growOnPlane(
      frame,
      start.x,
      start.y,
      plane,
      tolerance,
      seedDepth: seedDepth,
    );

    for (var pass = 0; pass < 5; pass++) {
      if (region.pixels.length < minRegionPixels) {
        return reject(
          FaceRejection.tooSmall,
          distance: seedDepth,
          seedTrouble: true,
          detail: 'region ${region.pixels.length}px, pass $pass',
        );
      }

      final fit = FaceSegmentation.fitRegion(frame, region.pixels);
      if (fit == null) break;

      plane = fit.plane;

      // Loose while the region is still growing, tight once it settles.
      final factor = pass < 2 ? 5.0 : 3.5;
      tolerance = FaceSegmentation.toleranceFor(
        fit.rmsMetres,
        seedDepth,
        factor: factor,
      );

      final next = FaceSegmentation.growOnPlane(
        frame,
        start.x,
        start.y,
        plane,
        tolerance,
        seedDepth: seedDepth,
      );

      final settled = (next.pixels.length - region.pixels.length).abs() <=
          0.015 * region.pixels.length;

      region = next;
      if (settled && pass >= 1) break;
    }

    if (region.pixels.length < minRegionPixels) {
      return reject(
        FaceRejection.tooSmall,
        distance: seedDepth,
        seedTrouble: true,
        detail: 'region ${region.pixels.length}px after refit',
      );
    }

    if (region.pixels.length > maxRegionPixels) {
      return reject(
        FaceRejection.notFlat,
        distance: seedDepth,
        detail: 'flat surface of ${region.pixels.length}px, too big for an end',
      );
    }

    // Pixels that are on the plane only because the ground crosses it. See
    // [FaceSegmentation.pruneOffPlaneNeighbours].
    final pruned = FaceSegmentation.pruneOffPlaneNeighbours(
      frame,
      plane,
      tolerance,
      region.pixels,
    );

    // Anything thinner than a few pixels is not part of the face: at the base
    // of a log lying on the ground the earth crosses the face's plane and
    // leaves a strip within tolerance that runs across the whole frame.
    final opening =
        (1.5 + tolerance * frame.fx / seedDepth).clamp(2.0, 5.0).toDouble();

    final seedIndex = start.y * frame.width + start.x;

    // One cell per log end. When the seed's region is a single end this
    // returns it untouched.
    final cell = FaceSegmentation.cellContaining(
      pixels: pruned,
      seed: seedIndex,
      width: frame.width,
      height: frame.height,
      openingPixels: opening,
    );

    if (cell.length < minRegionPixels) {
      return reject(
        FaceRejection.tooSmall,
        distance: seedDepth,
        seedTrouble: true,
        detail: 'cell ${cell.length}px of region ${region.pixels.length}px',
      );
    }

    final touches = _edgeContact(cell, frame.width, frame.height);

    // Fit on the pixels that were actually read as being on the plane. The
    // cell also holds pixels added by filling knots and hairline cracks, which
    // belong in the outline but have no face depth behind them -- and a
    // handful of readings of the wall behind is enough to wreck a plane fit.
    final onPlane = Uint8List(frame.width * frame.height);
    for (final index in region.pixels) {
      onPlane[index] = 1;
    }

    final readable = <int>[
      for (final index in cell)
        if (onPlane[index] != 0) index,
    ];

    final fit = FaceSegmentation.fitRegion(frame, readable);
    if (fit == null) {
      return reject(
        FaceRejection.notFlat,
        distance: seedDepth,
        detail: 'cell fit failed',
      );
    }

    final flatnessMm = fit.rmsMetres * 1000;
    if (flatnessMm > maxFlatnessMm) {
      return reject(
        FaceRejection.notFlat,
        distance: seedDepth,
        detail: 'rms ${flatnessMm.toStringAsFixed(1)}mm',
      );
    }

    final trace = _traceCell(frame, cell, fit.plane, bins, tolerance, onPlane);
    if (trace == null) {
      return reject(FaceRejection.outlineIncomplete, distance: seedDepth);
    }

    final outline = trace.outline;
    final distance = trace.distanceMetres;

    // Flat, or merely locally flat? See [maxCurvaturePerMetre].
    final faceRadius = math.max(outline.equivalentDiameterMetres / 2, 0.01);
    final noiseCurvature = noiseCurvatureFactor *
        FaceSegmentation.noiseFloor(distance) /
        (faceRadius * faceRadius);
    final curvatureLimit =
        math.max(maxCurvaturePerMetre, noiseCurvatureMargin * noiseCurvature);

    if (trace.curvature > curvatureLimit) {
      return reject(
        FaceRejection.notFlat,
        distance: distance,
        detail: 'curvature ${trace.curvature.toStringAsFixed(2)}/m '
            '(limit ${curvatureLimit.toStringAsFixed(2)})',
      );
    }

    if (distance < minRangeMetres) {
      return reject(FaceRejection.tooClose, distance: distance);
    }

    if (outline.equivalentDiameterMetres < minDiameterMetres) {
      return reject(
        FaceRejection.tooSmall,
        distance: distance,
        seedTrouble: true,
      );
    }

    // A band running clean across the view is the trunk, and telling the user
    // to step back would only show them more of it. They need to be told to
    // aim at the end instead, which is a different sentence entirely.
    final elongation = outline.minWidthMetres > 0
        ? outline.maxWidthMetres / outline.minWidthMetres
        : double.infinity;

    // A face held too close also runs edge to edge, but it comes out at
    // roughly the frame's own aspect -- it is the frame that is cropping it,
    // not the object that is long. Anything appreciably longer than that
    // while spanning the view is the trunk, and the two need opposite
    // instructions: step back, against turn and aim at the end.
    if (elongation > maxElongation ||
        (touches.spansOpposite && elongation > frameShapeAllowance)) {
      return reject(FaceRejection.pointingAtTheSide, distance: distance);
    }

    if (touches.any) {
      return reject(FaceRejection.runsOffScreen, distance: distance);
    }

    if (trace.tiltDegrees > maxTiltDegrees) {
      return reject(FaceRejection.tooAngled, distance: distance);
    }

    if (outline.observedFraction < minObservedFraction) {
      return reject(FaceRejection.outlineIncomplete, distance: distance);
    }

    // Last, because it is the only test that can reject a shape which passed
    // everything else. Refusing here is the right answer: a girth measured
    // round two logs at once is not a poor reading, it is a confident wrong
    // one, and the user can fix it in a second by shifting their aim.
    if (outline.compactness < minCompactness) {
      return reject(FaceRejection.moreThanOneLog, distance: distance);
    }

    return (
      attempt: FaceAttempt.found(
        FaceScan(
          centre: trace.centre,
          normal: trace.normal,
          distanceMetres: distance,
          tiltDegrees: trace.tiltDegrees,
          flatnessMm: flatnessMm,
          pointCount: cell.length,
          outline: outline,
          touchesFrameEdge: touches.any,
          curvaturePerMetre: trace.curvature,
        ),
      ),
      seedTrouble: false,
    );
  }

  /// The pixel with a usable reading nearest the seed.
  static ({int x, int y})? _nearestReadable(DepthFrame frame, int sx, int sy) {
    for (var radius = 0; radius <= 4; radius++) {
      for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
          if (math.max(dx.abs(), dy.abs()) != radius) continue;

          if (frame.depthAt(sx + dx, sy + dy) != null) {
            return (x: sx + dx, y: sy + dy);
          }
        }
      }
    }

    return null;
  }

  static ({bool any, bool spansOpposite}) _edgeContact(
    List<int> pixels,
    int width,
    int height,
  ) {
    var left = false, right = false, top = false, bottom = false;

    for (final index in pixels) {
      final x = index % width;
      final y = index ~/ width;

      if (x == 0) left = true;
      if (x == width - 1) right = true;
      if (y == 0) top = true;
      if (y == height - 1) bottom = true;
    }

    return (
      any: left || right || top || bottom,
      spansOpposite: (left && right) || (top && bottom),
    );
  }

  /// Turns one cell of pixels into a face: its centre and normal in world
  /// space, and its outline traced round the outside.
  ///
  /// A pixel's place on the face comes from where its line of sight crosses
  /// the fitted plane, not from its own depth reading. Depth decides *which*
  /// pixels are on the face; the ray decides *where* they are. That takes the
  /// sensor's noise out of the outline entirely: what is left is which pixels
  /// were counted in, and the sub-pixel edge below.
  static ({
    Vector3 centre,
    Vector3 normal,
    double distanceMetres,
    double tiltDegrees,
    FaceOutline outline,
    double curvature,
    double curvatureSigma,
  })? _traceCell(
    DepthFrame frame,
    List<int> cell,
    CameraPlane plane,
    int bins,
    double tolerance,
    Uint8List onPlane,
  ) {
    if (bins < 8 || bins.isOdd) return null;

    final count = cell.length;

    // Where a line of sight through an image position meets the plane, in
    // camera space.
    Vector3? cross(double x, double y) {
      final rx = (x - frame.cx) / frame.fx;
      final ry = -(y - frame.cy) / frame.fy;

      final k = plane.nx * rx + plane.ny * ry - plane.nz;
      if (k.abs() < 1e-9) return null;

      final t = plane.offset / k;
      if (!t.isFinite || t <= 0) return null;

      return Vector3(rx * t, ry * t, -t);
    }

    final xs = Float64List(count);
    final ys = Float64List(count);
    final zs = Float64List(count);
    final pixelOf = Int32List(count);

    var mx = 0.0, my = 0.0, mz = 0.0;
    var used = 0;

    for (final index in cell) {
      final p = cross(
        (index % frame.width).toDouble(),
        (index ~/ frame.width).toDouble(),
      );
      if (p == null) continue;

      xs[used] = p.x;
      ys[used] = p.y;
      zs[used] = p.z;
      pixelOf[used] = index;

      mx += p.x;
      my += p.y;
      mz += p.z;
      used++;
    }

    if (used < minRegionPixels) return null;

    mx /= used;
    my /= used;
    mz /= used;

    final centreCamera = Vector3(mx, my, mz);
    final distance = centreCamera.length;

    // Into world space, oriented back towards the camera so the normal is
    // always the direction the log runs away along and never its opposite.
    final rotation = frame.cameraTransform.getRotation();

    var normalCamera = Vector3(plane.nx, plane.ny, plane.nz);
    if (normalCamera.dot(-centreCamera) < 0) normalCamera = -normalCamera;

    final normalWorld = (rotation * normalCamera).normalized();
    final centreWorld = frame.toWorld(centreCamera);

    final lineOfSight = (frame.cameraPosition - centreWorld).normalized();
    final tilt = math.acos(normalWorld.dot(lineOfSight).clamp(-1.0, 1.0)) *
        180 /
        math.pi;

    final basis = perpendicularBasis(normalWorld);
    final inverse = rotation.transposed();
    final uCamera = inverse * basis.u;
    final vCamera = inverse * basis.v;

    // Bins no thinner than about two pixels of arc. A bin thinner than a pixel
    // often contains no pixel from the outermost ring at all, and reads short.
    final radiusPixels = math.sqrt(used / math.pi);
    final effectiveBins = math.min(
      bins,
      (2 * math.pi * radiusPixels / 2.0).round().clamp(16, bins).toInt(),
    );
    final binCount = effectiveBins.isOdd ? effectiveBins - 1 : effectiveBins;

    final binWidth = 2 * math.pi / binCount;
    final binRadii =
        List.generate(binCount, (_) => <double>[], growable: false);
    final binOuter = List<int>.filled(binCount, -1);
    final binOuterRadius = List<double>.filled(binCount, 0);

    // The area the pixels cover, on the plane. Each pixel is a small
    // parallelogram there -- stretched along the direction the face leans
    // away -- and its area is the cross product of its two sides.
    double planeT(double x, double y) {
      final rx = (x - frame.cx) / frame.fx;
      final ry = -(y - frame.cy) / frame.fy;
      final k = plane.nx * rx + plane.ny * ry - plane.nz;
      return plane.offset / k;
    }

    var pixelArea = 0.0;

    for (var i = 0; i < used; i++) {
      final index = pixelOf[i];
      final x = (index % frame.width).toDouble();
      final y = (index ~/ frame.width).toDouble();

      final t0 = planeT(x, y);
      final t1 = planeT(x + 1, y);
      final t2 = planeT(x, y + 1);

      final r0x = (x - frame.cx) / frame.fx;
      final r0y = -(y - frame.cy) / frame.fy;
      final r1x = (x + 1 - frame.cx) / frame.fx;
      final r2y = -(y + 1 - frame.cy) / frame.fy;

      // P = t * (rx, ry, -1). Two sides of the pixel's parallelogram.
      final ax = r1x * t1 - r0x * t0;
      final ay = r0y * t1 - r0y * t0;
      final az = -t1 + t0;

      final bx = r0x * t2 - r0x * t0;
      final by = r2y * t2 - r0y * t0;
      final bz = -t2 + t0;

      final ex = ay * bz - az * by;
      final ey = az * bx - ax * bz;
      final ez = ax * by - ay * bx;

      final area = math.sqrt(ex * ex + ey * ey + ez * ez);
      if (area.isFinite) pixelArea += area;
    }

    for (var i = 0; i < used; i++) {
      final ox = xs[i] - mx;
      final oy = ys[i] - my;
      final oz = zs[i] - mz;

      final a = ox * uCamera.x + oy * uCamera.y + oz * uCamera.z;
      final b = ox * vCamera.x + oy * vCamera.y + oz * vCamera.z;

      final radius = math.sqrt(a * a + b * b);
      if (!radius.isFinite || radius <= 0) continue;

      var angle = math.atan2(b, a);
      if (angle < 0) angle += 2 * math.pi;

      final bin = (angle / binWidth).floor().clamp(0, binCount - 1).toInt();
      binRadii[bin].add(radius);

      if (radius > binOuterRadius[bin]) {
        binOuterRadius[bin] = radius;
        binOuter[bin] = pixelOf[i];
      }
    }

    // Where the centre lands in the image, for walking outwards from it.
    final centreX = frame.cx + frame.fx * centreCamera.x / -centreCamera.z;
    final centreY = frame.cy - frame.fy * centreCamera.y / -centreCamera.z;

    final outer = List<double?>.filled(binCount, null);
    var bandArea = 0.0;

    for (var bin = 0; bin < binCount; bin++) {
      final samples = binRadii[bin];
      if (samples.isEmpty) continue;

      samples.sort();

      // The outermost few, averaged: the largest single return carries the
      // sensor's noise straight into the girth, the mean of the top few is
      // the boundary with the noise averaged down.
      final take = math.max(1, samples.length ~/ 20);
      var total = 0.0;
      for (var k = samples.length - take; k < samples.length; k++) {
        total += samples[k];
      }

      final index = binOuter[bin];
      final qx = (index % frame.width).toDouble();
      final qy = (index ~/ frame.width).toDouble();

      final outwardX = qx - centreX;
      final outwardY = qy - centreY;
      final outward = math.sqrt(outwardX * outwardX + outwardY * outwardY);

      // Half a pixel of reach, plus half of any smear band beyond the last
      // pixel the fill kept. Only the *shape* of the outline depends on this;
      // its size is set from the pixel area below.
      var reachMetres = 0.0;
      var bandMetres = 0.0;

      if (outward > 1e-6) {
        final band = _smearBandPixels(
          frame,
          plane,
          tolerance,
          qx.toInt(),
          qy.toInt(),
          outwardX,
          outwardY,
        );

        // Pixels are measured along the line of sight and turned into metres
        // on the plane, so a face seen at an angle -- whose pixels are
        // stretched along one direction -- is corrected by the right amount
        // whichever way the bin points.
        final ux = outwardX / outward;
        final uy = outwardY / outward;

        final near = cross(qx, qy);
        final half = cross(qx + ux * 0.5, qy + uy * 0.5);
        final smear =
            cross(qx + ux * (0.5 + band / 2), qy + uy * (0.5 + band / 2));

        if (near != null && half != null) reachMetres = (half - near).length;
        if (half != null && smear != null) bandMetres = (smear - half).length;
      }

      final radius = total / take + reachMetres + bandMetres;
      outer[bin] = radius;

      // Half the smear band belongs to the face: a strip along this bin's
      // stretch of the edge.
      bandArea += bandMetres * radius * binWidth;
    }

    final perimeterPixels = 2 * math.pi * radiusPixels;
    final harmonics = (perimeterPixels / 12).floor().clamp(3, 8).toInt();

    var outline = _buildOutline(
      outer: outer,
      u: basis.u,
      v: basis.v,
      harmonics: harmonics,
    );

    if (outline == null) return null;

    // The fitted curve gives the outline's *shape*. Its size comes from the
    // area of the pixels, which -- unlike the outermost pixel in each bin --
    // has no bias: a pixel's centre is in or out of the face at random phase,
    // and the areas of the ones that are in add up to the area of the face.
    // The outermost-pixel estimate reads short wherever a bin holds fewer
    // pixels than its arc is long, which on a small face is most of them.
    final measuredArea = pixelArea + bandArea;

    if (measuredArea > 0 && outline.areaMetres2 > 0) {
      final factor = math.sqrt(measuredArea / outline.areaMetres2);

      if (factor.isFinite && factor > 0.7 && factor < 1.4) {
        outline = outline.scaled(factor);
      }
    }

    final bend = _curvature(
      frame,
      plane,
      onPlane,
      pixelOf,
      xs,
      ys,
      zs,
      used,
      mx,
      my,
      mz,
      uCamera,
      vCamera,
    );

    return (
      centre: centreWorld,
      normal: normalWorld,
      distanceMetres: distance,
      tiltDegrees: tilt,
      outline: outline,
      curvature: bend.curvature,
      curvatureSigma: bend.sigma,
    );
  }

  /// The steepest curvature of the surface the cell's pixels lie on, in
  /// 1/metres, and how uncertain that figure is.
  ///
  /// Fits `d = c0 + c1 u + c2 v + a u^2 + b u v + c v^2` to the distance of
  /// each pixel's reading from the plane, over the face's own in-plane
  /// coordinates, and reads the Hessian's larger eigenvalue. The uncertainty
  /// comes from the fit's residual and how widely the pixels are spread: a
  /// small face gives a large uncertainty, and the caller widens its limit
  /// to match rather than refusing what it cannot judge.
  static ({double curvature, double sigma}) _curvature(
    DepthFrame frame,
    CameraPlane plane,
    Uint8List onPlane,
    Int32List pixelOf,
    Float64List xs,
    Float64List ys,
    Float64List zs,
    int used,
    double mx,
    double my,
    double mz,
    Vector3 uCamera,
    Vector3 vCamera,
  ) {
    final us = <double>[];
    final vs = <double>[];
    final ds = <double>[];

    for (var i = 0; i < used; i++) {
      final index = pixelOf[i];
      if (onPlane[index] == 0) continue;

      final x = index % frame.width;
      final y = index ~/ frame.width;

      final depth = frame.depthAt(x, y);
      if (depth == null) continue;

      final ox = xs[i] - mx;
      final oy = ys[i] - my;
      final oz = zs[i] - mz;

      us.add(ox * uCamera.x + oy * uCamera.y + oz * uCamera.z);
      vs.add(ox * vCamera.x + oy * vCamera.y + oz * vCamera.z);
      ds.add(plane.distance(frame, x, y, depth));
    }

    const unknown = (curvature: 0.0, sigma: 1e3);
    if (us.length < 30) return unknown;

    // Scale the coordinates so the normal equations are well conditioned.
    var scale = 0.0;
    for (var i = 0; i < us.length; i++) {
      scale = math.max(scale, math.max(us[i].abs(), vs[i].abs()));
    }
    if (scale <= 1e-6) return unknown;

    List<double> row(double u, double v) => [1, u, v, u * u, u * v, v * v];

    final keep = List<bool>.filled(us.length, true);
    List<double>? solution;
    var residual = 0.0;
    List<List<double>>? normal;

    for (var round = 0; round < 2; round++) {
      normal = List.generate(6, (_) => List<double>.filled(6, 0));
      final rhs = List<double>.filled(6, 0);
      var count = 0;

      for (var i = 0; i < us.length; i++) {
        if (!keep[i]) continue;

        final r = row(us[i] / scale, vs[i] / scale);
        count++;

        for (var a = 0; a < 6; a++) {
          rhs[a] += r[a] * ds[i];
          for (var b = 0; b < 6; b++) {
            normal[a][b] += r[a] * r[b];
          }
        }
      }

      if (count < 20) return unknown;

      solution = _solve(normal, rhs);
      if (solution == null) return unknown;

      var squared = 0.0;
      final errors = List<double>.filled(us.length, 0);

      for (var i = 0; i < us.length; i++) {
        final r = row(us[i] / scale, vs[i] / scale);
        var predicted = 0.0;
        for (var a = 0; a < 6; a++) {
          predicted += solution[a] * r[a];
        }
        errors[i] = ds[i] - predicted;
        if (keep[i]) squared += errors[i] * errors[i];
      }

      residual = math.sqrt(squared / count);

      // Second round without the pixels that sit far off the fitted surface.
      for (var i = 0; i < us.length; i++) {
        keep[i] = errors[i].abs() <= math.max(2.5 * residual, 0.003);
      }
    }

    final fit = solution!;

    // Coefficients are in scaled coordinates: d = ... + a (u/s)^2 + ...
    final a = fit[3] / (scale * scale);
    final b = fit[4] / (scale * scale);
    final c = fit[5] / (scale * scale);

    final mean = a + c;
    final spread = math.sqrt((a - c) * (a - c) + b * b);
    final curvature = math.max((mean + spread).abs(), (mean - spread).abs());

    // Uncertainty of each second-order coefficient: the residual over the
    // matching diagonal of the inverse normal matrix.
    double sigmaOf(int k) {
      final unit = List<double>.filled(6, 0)..[k] = 1;
      final column = _solve(normal!, unit);
      if (column == null || column[k] <= 0) return 1e3;
      return residual * math.sqrt(column[k]) / (scale * scale);
    }

    final sigma = 2 * math.max(sigmaOf(3), sigmaOf(5)) + sigmaOf(4);

    return (curvature: curvature, sigma: sigma);
  }

  /// The width, in pixels along the line of sight out from the face, of the
  /// smeared band beyond the last pixel the fill kept.
  ///
  /// A real depth map smears an edge: the pixels between the face and the
  /// background report something in between, or are dropped as low
  /// confidence. None of them is on the plane, so the fill stops before them,
  /// and counting only what the fill kept loses the whole band -- on both
  /// sides of the face.
  ///
  /// The edge lies in the middle of that band, so half of it is added back.
  /// That is exact for a sharp edge (no band, nothing added) and for any
  /// smear that is symmetric, whatever its width.
  ///
  /// The walk advances one pixel at a time along the dominant image axis, so
  /// every step lands on a fresh pixel however the bin points; a step of
  /// fixed length along a diagonal skips pixels and miscounts the band.
  static double _smearBandPixels(
    DepthFrame frame,
    CameraPlane plane,
    double tolerance,
    int qx,
    int qy,
    double directionX,
    double directionY,
  ) {
    final length = math.sqrt(directionX * directionX + directionY * directionY);
    if (length < 1e-6) return 0;

    final dx = directionX / length;
    final dy = directionY / length;

    final dominant = math.max(dx.abs(), dy.abs());
    final stepX = dx / dominant;
    final stepY = dy / dominant;

    // One dominant-axis step is this long along the line of sight.
    final stepLength = 1 / dominant;

    const reach = 6;

    // How far behind the plane each step is, or null where nothing was read.
    final behind = List<double?>.filled(reach + 1, null);

    for (var k = 1; k <= reach; k++) {
      final x = (qx + stepX * k).round();
      final y = (qy + stepY * k).round();

      if (x < 0 || y < 0 || x >= frame.width || y >= frame.height) {
        // Off the frame: cannot say. No band is claimed.
        if (k <= 2) return 0;
        continue;
      }

      final depth = frame.depthAt(x, y);
      if (depth == null) continue;

      // Still on the plane: the seam with a neighbouring face, not an edge.
      if (plane.distance(frame, x, y, depth).abs() <= tolerance) {
        if (k <= 2) return 0;
        continue;
      }

      final e = plane.alongRay(frame, x, y, depth);

      // In front of the plane is something between the camera and the face
      // -- the ground below a log's base, a hand -- and says nothing about
      // where the face ends.
      if (e < -tolerance) {
        if (k <= 2) return 0;
        continue;
      }

      behind[k] = e;
    }

    // The background level: what the far steps read, when they read it.
    final far = <double>[];
    for (var k = reach - 2; k <= reach; k++) {
      final e = behind[k];
      if (e != null && e > 0) far.add(e);
    }

    if (far.isEmpty) return 0;

    far.sort();
    final background = far[far.length ~/ 2];

    // No real step behind the face, so nothing to smear.
    if (background < 0.05) return 0;

    var band = 0;

    for (var k = 1; k <= reach - 3; k++) {
      final e = behind[k];

      if (e != null && e >= 0.8 * background) return band * stepLength;
      band++;
    }

    return 0;
  }

  /// Turns per-bin outer radii into an outline: a smooth closed curve fitted
  /// through them, its perimeter and its area.
  ///
  /// The radii are fitted with a short Fourier series rather than joined with
  /// straight lines. A face a dozen pixels across has an outline made of
  /// staircase steps, and the perimeter of a staircase is longer than the
  /// curve it approximates; a few harmonics keep the ovality, the lobes and
  /// the flats of a real log end and drop the pixel-scale jitter. It also
  /// fills a gap where a bin saw nothing with the shape the rest of the
  /// outline implies, rather than with a straight line across it.
  static FaceOutline? _buildOutline({
    required List<double?> outer,
    required Vector3 u,
    required Vector3 v,
    required int harmonics,
  }) {
    final bins = outer.length;
    final binWidth = 2 * math.pi / bins;

    bool usable(int i) {
      final r = outer[i];
      return r != null && r.isFinite && r > 0;
    }

    var observed = 0;
    var mean = 0.0;

    for (var i = 0; i < bins; i++) {
      if (!usable(i)) continue;
      observed++;
      mean += outer[i]!;
    }

    if (observed < bins ~/ 2) return null;
    mean /= observed;

    final terms = 1 + 2 * harmonics;

    double basis(int term, double angle) {
      if (term == 0) return 1;
      final k = (term + 1) ~/ 2;
      return term.isOdd ? math.cos(k * angle) : math.sin(k * angle);
    }

    double evaluate(List<double> c, double angle) {
      var total = 0.0;
      for (var t = 0; t < c.length; t++) {
        total += c[t] * basis(t, angle);
      }
      return total;
    }

    // Weighted least squares on radii relative to the mean, with a small
    // penalty on the higher harmonics, and two rounds of down-weighting for
    // bins that sit far from the curve the others agree on.
    final weights = List<double>.generate(bins, (i) => usable(i) ? 1.0 : 0.0);

    var coefficients = List<double>.filled(terms, 0);

    for (var round = 0; round < 3; round++) {
      final normal = List.generate(terms, (_) => List<double>.filled(terms, 0));
      final rhs = List<double>.filled(terms, 0);

      for (var i = 0; i < bins; i++) {
        final w = weights[i];
        if (w <= 0) continue;

        final angle = (i + 0.5) * binWidth;
        final y = outer[i]! / mean;

        for (var a = 0; a < terms; a++) {
          final ba = basis(a, angle);
          rhs[a] += w * ba * y;

          for (var b = 0; b < terms; b++) {
            normal[a][b] += w * ba * basis(b, angle);
          }
        }
      }

      for (var a = 1; a < terms; a++) {
        final k = (a + 1) ~/ 2;
        normal[a][a] += 1e-4 * k * k * k * k;
      }

      final solved = _solve(normal, rhs);
      if (solved == null) return null;
      coefficients = solved;

      if (round == 2) break;

      final residuals = <double>[];
      for (var i = 0; i < bins; i++) {
        if (!usable(i)) continue;
        residuals.add(
          (outer[i]! / mean - evaluate(coefficients, (i + 0.5) * binWidth))
              .abs(),
        );
      }

      residuals.sort();
      final scale = math.max(1.4826 * residuals[residuals.length ~/ 2], 0.004);

      for (var i = 0; i < bins; i++) {
        if (!usable(i)) continue;

        final r =
            (outer[i]! / mean - evaluate(coefficients, (i + 0.5) * binWidth))
                .abs();

        weights[i] = r <= 1.5 * scale ? 1.0 : 1.5 * scale / r;
      }
    }

    // The curve, sampled finely enough that the polygon through it is the
    // curve for every practical purpose.
    const samples = 360;
    final step = 2 * math.pi / samples;

    var perimeter = 0.0;
    var area = 0.0;

    var previousX = 0.0, previousY = 0.0;
    var firstX = 0.0, firstY = 0.0;

    for (var i = 0; i < samples; i++) {
      final angle = i * step;
      final r = evaluate(coefficients, angle) * mean;

      if (!r.isFinite || r <= 0) return null;

      final x = r * math.cos(angle);
      final y = r * math.sin(angle);

      if (i == 0) {
        firstX = x;
        firstY = y;
      } else {
        perimeter += math.sqrt(
          (x - previousX) * (x - previousX) + (y - previousY) * (y - previousY),
        );
        area += 0.5 * (previousX * y - x * previousY);
      }

      previousX = x;
      previousY = y;
    }

    // Close the polygon back to the first sample.
    perimeter += math.sqrt(
      (firstX - previousX) * (firstX - previousX) +
          (firstY - previousY) * (firstY - previousY),
    );
    area += 0.5 * (previousX * firstY - firstX * previousY);

    area = area.abs();

    if (!perimeter.isFinite || perimeter <= 0) return null;
    if (!area.isFinite || area <= 0) return null;

    final radii = List<double>.generate(
      bins,
      (i) => evaluate(coefficients, (i + 0.5) * binWidth) * mean,
    );

    return FaceOutline(
      radii: radii,
      perimeterMetres: perimeter,
      areaMetres2: area,
      observedFraction: observed / bins,
      u: u,
      v: v,
    );
  }

  /// Solves `a x = b` by Gaussian elimination with partial pivoting.
  static List<double>? _solve(List<List<double>> a, List<double> b) {
    final n = b.length;
    final m = [
      for (var i = 0; i < n; i++) [...a[i], b[i]],
    ];

    for (var col = 0; col < n; col++) {
      var pivot = col;
      for (var row = col + 1; row < n; row++) {
        if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
      }

      if (m[pivot][col].abs() < 1e-12) return null;

      final swap = m[col];
      m[col] = m[pivot];
      m[pivot] = swap;

      for (var row = col + 1; row < n; row++) {
        final factor = m[row][col] / m[col][col];
        if (factor == 0) continue;

        for (var k = col; k <= n; k++) {
          m[row][k] -= factor * m[col][k];
        }
      }
    }

    final x = List<double>.filled(n, 0);

    for (var row = n - 1; row >= 0; row--) {
      var total = m[row][n];
      for (var k = row + 1; k < n; k++) {
        total -= m[row][k] * x[k];
      }
      x[row] = total / m[row][row];
    }

    return x;
  }

  /// The pixels of one continuous surface, grown outwards from a seed while
  /// depth stays continuous.
  ///
  /// No longer how faces are found -- see the class comment -- but the trunk
  /// profiler reads a log's side with it, where following a surface as it
  /// recedes round the curve is exactly right.
  static ({List<int> pixels, bool touchesEdge, bool spansOppositeEdges})
      growRegion(
    DepthFrame frame,
    int seedX,
    int seedY,
    double seedDepth, {
    double stepMetres = stepToleranceMetres,
    double spreadMetres = depthSpreadMetres,
  }) {
    final width = frame.width;
    final height = frame.height;
    final total = width * height;

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

        final neighbourDepth = frame.depthAt(nx, ny);
        if (neighbourDepth == null) continue;

        // Continuous with the pixel it was reached from, and still part of
        // the same object as the seed. The first test follows a surface that
        // recedes; the second stops it following one for ever.
        if ((neighbourDepth - depth).abs() > stepMetres) continue;
        if ((neighbourDepth - seedDepth).abs() > spreadMetres) continue;

        visited[neighbour] = 1;
        queue[tail++] = neighbour;
      }
    }

    return (
      pixels: pixels,
      touchesEdge:
          touchesLeft || touchesRight || touchesTop || touchesBottom,
      spansOppositeEdges:
          (touchesLeft && touchesRight) || (touchesTop && touchesBottom),
    );
  }

  /// Traces the outline of a set of coplanar world-space points about their
  /// centre.
  ///
  /// The general form of what [detect] does for pixels, for callers that
  /// already hold points -- recorded clouds, and the tests that check the
  /// girth model against a known outline.
  static FaceOutline? traceOutline({
    required List<Vector3> points,
    required Vector3 centre,
    required Vector3 normal,
    int bins = outlineBins,
    double edgeExtensionMetres = 0,
  }) {
    if (points.length < 16 || bins < 8 || bins.isOdd) return null;

    final basis = perpendicularBasis(normal);
    final u = basis.u;
    final v = basis.v;

    final binRadii = List.generate(bins, (_) => <double>[], growable: false);
    final binWidth = 2 * math.pi / bins;

    for (final p in points) {
      final offset = p - centre;

      final x = offset.dot(u);
      final y = offset.dot(v);

      final radius = math.sqrt(x * x + y * y);
      if (!radius.isFinite || radius <= 0) continue;

      var angle = math.atan2(y, x);
      if (angle < 0) angle += 2 * math.pi;

      final index = (angle / binWidth).floor().clamp(0, bins - 1).toInt();
      binRadii[index].add(radius);
    }

    final outer = List<double?>.filled(bins, null);
    var sum = 0.0;
    var seen = 0;

    for (var i = 0; i < bins; i++) {
      final samples = binRadii[i];
      if (samples.isEmpty) continue;

      samples.sort();

      final take = math.max(1, samples.length ~/ 20);
      var total = 0.0;
      for (var k = samples.length - take; k < samples.length; k++) {
        total += samples[k];
      }

      final radius = total / take + edgeExtensionMetres;
      outer[i] = radius;
      sum += radius;
      seen++;
    }

    if (seen == 0) return null;

    // About one harmonic per 2 cm of perimeter, within sensible bounds.
    final harmonics =
        (2 * math.pi * (sum / seen) / 0.02).floor().clamp(3, 8).toInt();

    return _buildOutline(outer: outer, u: u, v: v, harmonics: harmonics);
  }
}
