import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'depth_frame.dart';

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

  const FaceScan({
    required this.centre,
    required this.normal,
    required this.distanceMetres,
    required this.tiltDegrees,
    required this.flatnessMm,
    required this.pointCount,
    required this.outline,
    required this.touchesFrameEdge,
  });

  /// The girth of the face: what a tape round the cut end reads.
  double get girthMetres => outline.perimeterMetres;

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

  const FaceAttempt.found(FaceScan this.face)
      : rejection = null,
        distanceMetres = null;

  const FaceAttempt.rejected(this.rejection, {this.distanceMetres})
      : face = null;

  bool get isFound => face != null;
}

/// Finds the flat cut end of a log in a depth frame.
///
/// The method is deliberately not a plane search over the whole scene, and
/// not a circle fit. It grows a region outwards from the middle of the frame
/// while the depth stays continuous, which stops of its own accord at the
/// cliff where the face ends and the background begins. That works on a face
/// that is oval, rough, chainsawn at an angle, or resting against other
/// logs -- none of which a plane detector or a circle fit survives.
///
/// The previous scanner asked the user to tap the log and then resolved that
/// tap through a plane raycast. A log end offers no plane to estimate and no
/// texture to latch onto, so the tap silently missed and the scan could never
/// start. Nothing here needs a tap at all: the user points, and the middle of
/// the frame is the answer.
class FaceScanner {
  const FaceScanner._();

  /// Angular bins the outline is traced in. One every 7.5 degrees: fine
  /// enough to follow the lobes and flats of a real log end, coarse enough
  /// that each bin still collects several returns and its boundary estimate
  /// stays steady.
  static const int outlineBins = 48;

  /// Two neighbouring pixels belong to the same surface while their depths
  /// agree to within this. Larger than sensor noise, far smaller than the
  /// step from a log end to whatever is behind it.
  static const double stepToleranceMetres = 0.025;

  /// How far in depth the region may wander from the seed. A 60 cm face
  /// tilted 40 degrees spans about 38 cm front to back, so this leaves room
  /// for a big log seen at an awkward angle and still stops the fill
  /// escaping down the length of the trunk.
  static const double depthSpreadMetres = 0.50;

  /// Working range. Closer than this the sensor is in its blind zone and the
  /// face overflows the frame; further away the returns thin out until an
  /// outline cannot be traced.
  static const double minRangeMetres = 0.25;
  static const double maxRangeMetres = 2.5;

  /// Below this the region is too small to be a log end at this range.
  static const int minRegionPixels = 60;

  /// Roughness a cut face is allowed, as millimetres and as a share of its
  /// own half-width.
  ///
  /// A sawn end is a few millimetres out of plane and a badly chainsawn one
  /// perhaps fifteen. The curved side of a trunk is about a fifth of its
  /// radius -- 30 mm on a 30 cm log -- so 25 mm separates the two with room
  /// on both sides.
  static const double maxFlatnessMm = 25;
  static const double maxFlatnessFraction = 0.12;

  /// Longer than this, relative to its own narrow way across, and what has
  /// been found is a band of trunk lying across the view, not an end.
  static const double maxElongation = 2.4;

  /// A face cropped by the frame reads at the frame's own aspect, near 1.33.
  /// This sits above that, so a cropped end is told to step back while a
  /// band of trunk is told to aim at the end.
  static const double frameShapeAllowance = 1.6;

  /// Beyond this the user is looking along the log rather than at its end,
  /// and the outline they would get is the silhouette of the trunk.
  static const double maxTiltDegrees = 45;

  /// Share of the outline that must come from real returns rather than be
  /// filled in between them.
  static const double minObservedFraction = 0.80;

  /// Share of the first pass a plane-confined second pass must keep before
  /// it is believed. See where it is used for why a trunk fails it.
  static const double minRefinementRetention = 0.55;

  /// How nearly circular an outline must be to be one log end.
  ///
  /// A circle is 1.0, an oval end about 0.97, a badly lobed one 0.93, and
  /// even a split half-round 0.75. Two ends touching in a stack trace as a
  /// peanut at about 0.56, so this sits in the wide gap between the worst
  /// real log end and the best accidental pair.
  static const double minCompactness = 0.68;

  /// The surface extends to the edge of the last pixel that saw it, not to
  /// that pixel's centre, so every traced radius is short by half a pixel.
  /// At half a metre that is about two millimetres -- small, but it biases
  /// every girth the same way, and a bias is worth removing.
  static const double edgePixelExtension = 0.5;

  /// Tries to resolve a cut face from one frame.
  ///
  /// [seedX]/[seedY] default to the middle of the frame, which is where the
  /// reticle is.
  static FaceAttempt detect(
    DepthFrame frame, {
    int? seedX,
    int? seedY,
    int bins = outlineBins,
  }) {
    final sx = seedX ?? frame.width ~/ 2;
    final sy = seedY ?? frame.height ~/ 2;

    final seedDepth = frame.medianDepthAround(sx, sy);
    if (seedDepth == null) return const FaceAttempt.rejected(FaceRejection.noDepth);

    if (seedDepth < minRangeMetres) {
      return FaceAttempt.rejected(
        FaceRejection.tooClose,
        distanceMetres: seedDepth,
      );
    }

    if (seedDepth > maxRangeMetres) {
      return FaceAttempt.rejected(
        FaceRejection.tooFar,
        distanceMetres: seedDepth,
      );
    }

    var region = growRegion(frame, sx, sy, seedDepth);

    if (region.pixels.length < minRegionPixels) {
      return FaceAttempt.rejected(
        FaceRejection.tooSmall,
        distanceMetres: seedDepth,
      );
    }

    var points = _worldPoints(frame, region.pixels);
    var plane = PlaneFit.fit(points);

    if (plane == null) {
      return FaceAttempt.rejected(
        FaceRejection.notFlat,
        distanceMetres: seedDepth,
      );
    }

    // Judge flatness here, on the raw region, before the refinement below is
    // allowed to improve it.
    //
    // This ordering is the whole defence against measuring the trunk. Point
    // at the side of a log and the first pass finds the curved surface,
    // which is emphatically not flat -- but a plane fitted through it and
    // then used to re-grow the region carves out a band that is, and that
    // band would go on to pass every remaining test as a "face" a metre
    // wide. Asking the question before the answer can be tidied up is the
    // only reliable way round that.
    if (plane.rmsMetres * 1000 > maxFlatnessMm) {
      return FaceAttempt.rejected(
        FaceRejection.notFlat,
        distanceMetres: seedDepth,
      );
    }

    // Second pass, confined to the plane the first pass found.
    //
    // Without it the fill leaks: where a log rests against its neighbour, or
    // where the end curves into the bark, depth stays continuous and the
    // region walks straight off the face. Re-growing with a plane test as
    // well as a depth test stops at the edge of the end even when there is
    // no depth cliff there at all.
    final planeTolerance =
        (3 * plane.rmsMetres).clamp(0.012, 0.030).toDouble();

    final refined = growRegion(
      frame,
      sx,
      sy,
      seedDepth,
      plane: plane,
      planeToleranceMetres: planeTolerance,
    );

    // Only adopt the plane-confined pass if it kept most of what was there.
    //
    // Point the camera at the trunk instead of the end and the first pass
    // finds the curved side, which is not flat at all -- but a plane fitted
    // through it carves out a narrow strip that is, and the strip would then
    // sail through every flatness test as a "face" a metre wide. Keeping the
    // refinement only when it retains the bulk of the region means a genuine
    // end (where it changes almost nothing) is refined and a trunk (where it
    // discards four fifths) is left to be judged on its real roughness.
    if (refined.pixels.length >= minRegionPixels &&
        refined.pixels.length >= region.pixels.length * minRefinementRetention) {
      final refinedPoints = _worldPoints(frame, refined.pixels);
      final refinedPlane = PlaneFit.fit(refinedPoints);

      if (refinedPlane != null) {
        region = refined;
        points = refinedPoints;
        plane = refinedPlane;
      }
    }

    if (points.length < minRegionPixels) {
      return FaceAttempt.rejected(
        FaceRejection.tooSmall,
        distanceMetres: seedDepth,
      );
    }

    final camera = frame.cameraPosition;
    final centre = plane.origin;

    final toCamera = camera - centre;
    final distance = toCamera.length;

    if (distance < minRangeMetres) {
      return FaceAttempt.rejected(
        FaceRejection.tooClose,
        distanceMetres: distance,
      );
    }

    // Point the normal back at the viewer, so it is always the direction the
    // log runs away along and never its opposite.
    var normal = plane.normal.normalized();
    if (normal.dot(toCamera) < 0) normal = -normal;

    final lineOfSight = toCamera.normalized();
    final cosine = normal.dot(lineOfSight).clamp(-1.0, 1.0);
    final tilt = math.acos(cosine) * 180 / math.pi;

    final outline = traceOutline(
      points: points,
      centre: centre,
      normal: normal,
      bins: bins,
      edgeExtensionMetres:
          edgePixelExtension * distance / (frame.fx <= 0 ? 1e9 : frame.fx),
    );

    if (outline == null) {
      return FaceAttempt.rejected(
        FaceRejection.outlineIncomplete,
        distanceMetres: distance,
      );
    }

    final flatnessMm = plane.rmsMetres * 1000;

    // The same question again, now against the size of what was found. A
    // small piece is allowed proportionally less roughness than a big one,
    // and the narrow way across is the right scale to judge it by: on a band
    // of trunk the long direction is however much of it was in frame, which
    // says nothing about the curve being measured.
    final halfWidth = outline.minWidthMetres / 2;

    if (flatnessMm > maxFlatnessMm ||
        (halfWidth > 0 &&
            plane.rmsMetres > halfWidth * maxFlatnessFraction)) {
      return FaceAttempt.rejected(
        FaceRejection.notFlat,
        distanceMetres: distance,
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
        (region.spansOppositeEdges && elongation > frameShapeAllowance)) {
      return FaceAttempt.rejected(
        FaceRejection.pointingAtTheSide,
        distanceMetres: distance,
      );
    }

    if (region.touchesEdge) {
      return FaceAttempt.rejected(
        FaceRejection.runsOffScreen,
        distanceMetres: distance,
      );
    }

    if (tilt > maxTiltDegrees) {
      return FaceAttempt.rejected(
        FaceRejection.tooAngled,
        distanceMetres: distance,
      );
    }

    if (outline.observedFraction < minObservedFraction) {
      return FaceAttempt.rejected(
        FaceRejection.outlineIncomplete,
        distanceMetres: distance,
      );
    }

    // Last, because it is the only test that can reject a shape which passed
    // everything else. Refusing here is the right answer: a girth measured
    // round two logs at once is not a poor reading, it is a confident wrong
    // one, and the user can fix it in a second by shifting their aim.
    if (outline.compactness < minCompactness) {
      return FaceAttempt.rejected(
        FaceRejection.moreThanOneLog,
        distanceMetres: distance,
      );
    }

    return FaceAttempt.found(
      FaceScan(
        centre: centre,
        normal: normal,
        distanceMetres: distance,
        tiltDegrees: tilt,
        flatnessMm: flatnessMm,
        pointCount: points.length,
        outline: outline,
        touchesFrameEdge: region.touchesEdge,
      ),
    );
  }

  /// The pixels of one continuous surface, grown outwards from a seed.
  ///
  /// Exposed for testing: this is where a face stops being a face, and the
  /// rules it stops on decide every measurement downstream.
  static ({List<int> pixels, bool touchesEdge, bool spansOppositeEdges})
      growRegion(
    DepthFrame frame,
    int seedX,
    int seedY,
    double seedDepth, {
    PlaneFit? plane,
    double planeToleranceMetres = 0,
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

      if (plane != null) {
        final point = frame.toWorld(frame.cameraPointAt(x, y, depth));
        if (plane.distanceTo(point).abs() > planeToleranceMetres) continue;
      }

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

  /// Traces the outline of a set of coplanar points about their centre.
  ///
  /// Each angular bin reports the mean of its outermost few radii rather
  /// than its single largest: the largest is whichever return happened to
  /// land furthest out, so it carries the sensor's noise straight into the
  /// girth, while the mean of the top few is the boundary with the noise
  /// averaged down.
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

      final index = (angle / binWidth).floor().clamp(0, bins - 1);
      binRadii[index].add(radius);
    }

    final radii = List<double>.filled(bins, 0);
    var observed = 0;

    for (var i = 0; i < bins; i++) {
      final samples = binRadii[i];
      if (samples.isEmpty) continue;

      samples.sort();

      // The outermost few, averaged. One in twenty, so a densely sampled bin
      // averages more of them and a thin one still reports something.
      final take = math.max(1, samples.length ~/ 20);
      var total = 0.0;
      for (var k = samples.length - take; k < samples.length; k++) {
        total += samples[k];
      }

      radii[i] = total / take + edgeExtensionMetres;
      observed++;
    }

    if (observed < bins ~/ 2) return null;

    _fillGaps(radii, binRadii);
    _clampSpikes(radii);

    var perimeter = 0.0;
    var area = 0.0;

    for (var i = 0; i < bins; i++) {
      final a = radii[i];
      final b = radii[(i + 1) % bins];

      // Law of cosines on the two radii and the angle between bin centres.
      final squared = a * a + b * b - 2 * a * b * math.cos(binWidth);
      perimeter += math.sqrt(squared <= 0 ? 0 : squared);

      area += 0.5 * a * b * math.sin(binWidth);
    }

    // A polygon inscribed in a curve is always short of it. For a circle the
    // shortfall is exactly sin(pi/n)/(pi/n) on the perimeter and
    // sin(2pi/n)/(2pi/n) on the area, so correcting by their reciprocals
    // makes a round face trace to exactly pi*d and pi*r^2, and leaves a
    // lobed one very close to its true size.
    perimeter *= (math.pi / bins) / math.sin(math.pi / bins);
    area *= (2 * math.pi / bins) / math.sin(2 * math.pi / bins);

    if (!perimeter.isFinite || perimeter <= 0) return null;
    if (!area.isFinite || area <= 0) return null;

    return FaceOutline(
      radii: radii,
      perimeterMetres: perimeter,
      areaMetres2: area,
      observedFraction: observed / bins,
      u: u,
      v: v,
    );
  }

  /// Completes bins that saw nothing by walking round to the nearest bin
  /// that did, in each direction, and interpolating between them.
  static void _fillGaps(List<double> radii, List<List<double>> samples) {
    final bins = radii.length;

    for (var i = 0; i < bins; i++) {
      if (samples[i].isNotEmpty) continue;

      var back = 1;
      while (back < bins && samples[(i - back + bins) % bins].isEmpty) {
        back++;
      }

      var forward = 1;
      while (forward < bins && samples[(i + forward) % bins].isEmpty) {
        forward++;
      }

      if (back >= bins || forward >= bins) continue;

      final a = radii[(i - back + bins) % bins];
      final b = radii[(i + forward) % bins];

      radii[i] = a + (b - a) * (back / (back + forward));
    }
  }

  /// Pulls in bins that stand far outside the rest of the outline.
  ///
  /// A bin reaching half again as far as the body of the face is a leak onto
  /// the log beside it or a stray return off an edge, not a lobe -- an oval
  /// log end spans about 1.2 of its own median, and a badly lobed one 1.3,
  /// so the limit here sits clear above both.
  ///
  /// Pulled down to the *smaller* of its two neighbours rather than to their
  /// average, and in a single forward pass, so that a run of several
  /// contaminated bins collapses rather than propagating its excess
  /// inwards one bin at a time. Understating is also the safe direction for
  /// a figure someone is paid on.
  static void _clampSpikes(List<double> radii) {
    final bins = radii.length;
    if (bins < 5) return;

    final sorted = [...radii]..sort();
    final median = sorted[bins ~/ 2];
    if (median <= 0) return;

    final limit = median * 1.45;

    for (var i = 0; i < bins; i++) {
      if (radii[i] <= limit) continue;

      final before = radii[(i - 1 + bins) % bins];
      final after = radii[(i + 1) % bins];

      radii[i] = math.min(
        radii[i],
        math.max(median, math.min(before, after)),
      );
    }
  }

  static List<Vector3> _worldPoints(DepthFrame frame, List<int> pixels) {
    final points = <Vector3>[];
    points.length = 0;

    for (final index in pixels) {
      final x = index % frame.width;
      final y = index ~/ frame.width;

      final depth = frame.depthAt(x, y);
      if (depth == null) continue;

      points.add(frame.toWorld(frame.cameraPointAt(x, y, depth)));
    }

    return points;
  }
}
