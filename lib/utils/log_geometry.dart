import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Turns a depth-sensor point cloud into a log's diameter profile.
///
/// All of this is pure Dart on purpose. The native side only captures
/// points; every accuracy-critical decision happens here, where it can be
/// unit-tested against synthetic cylinders on a machine with no device.
///
/// Units are metres throughout -- conversion to trade units happens at the
/// UI boundary via `MeasurementUnits`.

/// A circle fitted to one cross-section of the log.
class CircleFit {
  final Vector2 center;
  final double radius;

  /// Root-mean-square radial distance of the points from the fitted circle.
  final double rmsResidual;

  /// How much of the circle the points actually cover. The sensor only sees
  /// the front of a log, so this is typically well under 2*pi -- and a
  /// narrow arc makes the fit ill-conditioned.
  final double angularSpanRadians;

  final int pointCount;

  const CircleFit({
    required this.center,
    required this.radius,
    required this.rmsResidual,
    required this.angularSpanRadians,
    required this.pointCount,
  });

  double get angularSpanDegrees => angularSpanRadians * 180 / math.pi;
}

/// One slice through the log, perpendicular to its axis.
class CrossSection {
  /// Distance along the axis from the profile's start, in metres.
  final double axialPosition;

  final Vector3 center;
  final double radius;
  final double rmsResidual;
  final double angularSpanRadians;
  final int pointCount;

  const CrossSection({
    required this.axialPosition,
    required this.center,
    required this.radius,
    required this.rmsResidual,
    required this.angularSpanRadians,
    required this.pointCount,
  });

  double get diameter => radius * 2;

  double get angularSpanDegrees => angularSpanRadians * 180 / math.pi;
}

class LogAxis {
  final Vector3 origin;

  /// Unit vector along the log.
  final Vector3 direction;

  const LogAxis({required this.origin, required this.direction});
}

class LogProfile {
  final LogAxis axis;

  /// Sections that passed the quality gates, ordered along the axis.
  final List<CrossSection> sections;

  /// Sections that were measured but rejected -- kept so the UI can explain
  /// *why* a scan was poor rather than just scoring it.
  final List<CrossSection> rejectedSections;

  final double lengthMetres;

  const LogProfile({
    required this.axis,
    required this.sections,
    required this.rejectedSections,
    required this.lengthMetres,
  });

  List<double> get diametersMetres =>
      sections.map((s) => s.diameter).toList(growable: false);

  /// Smallest angular span among accepted sections -- the limiting factor
  /// for how much the whole profile can be trusted.
  double? get minAngularSpanDegrees {
    if (sections.isEmpty) return null;

    return sections
        .map((s) => s.angularSpanDegrees)
        .reduce((a, b) => a < b ? a : b);
  }

  double? get meanResidualMetres {
    if (sections.isEmpty) return null;

    final total = sections.fold<double>(0, (sum, s) => sum + s.rmsResidual);
    return total / sections.length;
  }
}

class LogGeometry {
  /// Sections spanning less than this are discarded: fitting a circle to a
  /// short arc is ill-conditioned and its radius error grows non-linearly.
  static const double minAngularSpanRadians = 110 * math.pi / 180;

  /// Points further than this multiple of the running radius from the axis
  /// are treated as a neighbouring log or background, not this log.
  static const double radialGateFactor = 1.5;

  /// Fits a circle by the Taubin method.
  ///
  /// Taubin rather than the simpler Kasa fit specifically because the data
  /// is a partial arc: Kasa is systematically biased low on arcs (several
  /// percent at 150 degrees), and diameter error squares into volume error.
  static CircleFit? fitCircleTaubin(List<Vector2> points) {
    if (points.length < 3) return null;

    final n = points.length;

    double meanX = 0, meanY = 0;
    for (final p in points) {
      meanX += p.x;
      meanY += p.y;
    }
    meanX /= n;
    meanY /= n;

    double mxx = 0, myy = 0, mxy = 0, mxz = 0, myz = 0, mzz = 0;

    for (final p in points) {
      final xi = p.x - meanX;
      final yi = p.y - meanY;
      final zi = xi * xi + yi * yi;

      mxx += xi * xi;
      myy += yi * yi;
      mxy += xi * yi;
      mxz += xi * zi;
      myz += yi * zi;
      mzz += zi * zi;
    }

    mxx /= n;
    myy /= n;
    mxy /= n;
    mxz /= n;
    myz /= n;
    mzz /= n;

    final mz = mxx + myy;
    final covXy = mxx * myy - mxy * mxy;
    final varZ = mzz - mz * mz;

    final a3 = 4 * mz;
    final a2 = -3 * mz * mz - mzz;
    final a1 = varZ * mz + 4 * covXy * mz - mxz * mxz - myz * myz;
    final a0 =
        mxz * (mxz * myy - myz * mxy) + myz * (myz * mxx - mxz * mxy) -
            varZ * covXy;

    final a22 = a2 + a2;
    final a33 = a3 + a3 + a3;

    // Newton's method on the Taubin characteristic polynomial, starting at
    // the root nearest zero.
    double x = 0;
    double y = a0;

    for (var iter = 0; iter < 99; iter++) {
      final dy = a1 + x * (a22 + a33 * x);
      if (dy == 0) break;

      final xNew = x - y / dy;
      if (xNew == x || !xNew.isFinite) break;

      final yNew = a0 + xNew * (a1 + xNew * (a2 + xNew * a3));
      if (yNew.abs() >= y.abs()) break;

      x = xNew;
      y = yNew;
    }

    final det = x * x - x * mz + covXy;
    if (det == 0 || !det.isFinite) return null;

    final centerX = (mxz * (myy - x) - myz * mxy) / det / 2;
    final centerY = (myz * (mxx - x) - mxz * mxy) / det / 2;

    final radius =
        math.sqrt(centerX * centerX + centerY * centerY + mz);

    if (!radius.isFinite || radius <= 0) return null;

    final center = Vector2(centerX + meanX, centerY + meanY);

    return CircleFit(
      center: center,
      radius: radius,
      rmsResidual: _rmsResidual(points, center, radius),
      angularSpanRadians: angularSpan(points, center),
      pointCount: n,
    );
  }

  /// Fits a circle while rejecting outliers -- bark flakes, branch stubs,
  /// and surfaces belonging to a neighbouring log in a stack.
  static CircleFit? fitCircleRansac(
    List<Vector2> points, {
    double inlierToleranceMetres = 0.01,
    int iterations = 120,
    int? seed,
  }) {
    if (points.length < 3) return null;
    if (points.length < 8) return fitCircleTaubin(points);

    final random = math.Random(seed ?? 12345);

    List<Vector2>? bestInliers;

    for (var i = 0; i < iterations; i++) {
      final a = points[random.nextInt(points.length)];
      final b = points[random.nextInt(points.length)];
      final c = points[random.nextInt(points.length)];

      final candidate = _circumcircle(a, b, c);
      if (candidate == null) continue;

      final inliers = <Vector2>[];
      for (final p in points) {
        final distance = (p - candidate.center).length;
        if ((distance - candidate.radius).abs() <= inlierToleranceMetres) {
          inliers.add(p);
        }
      }

      if (bestInliers == null || inliers.length > bestInliers.length) {
        bestInliers = inliers;
      }
    }

    if (bestInliers == null || bestInliers.length < 3) {
      return fitCircleTaubin(points);
    }

    // Refit properly on the consensus set: RANSAC picks the inliers, Taubin
    // gets the accurate radius from them.
    return fitCircleTaubin(bestInliers) ?? fitCircleTaubin(points);
  }

  /// Angular coverage of [points] about [center], in radians.
  ///
  /// Found as 2*pi minus the largest angular gap, so a set of points
  /// covering one continuous arc reports that arc's width.
  static double angularSpan(List<Vector2> points, Vector2 center) {
    if (points.length < 2) return 0;

    final angles = points
        .map((p) => math.atan2(p.y - center.y, p.x - center.x))
        .toList()
      ..sort();

    var largestGap = (angles.first + 2 * math.pi) - angles.last;

    for (var i = 1; i < angles.length; i++) {
      final gap = angles[i] - angles[i - 1];
      if (gap > largestGap) largestGap = gap;
    }

    final span = 2 * math.pi - largestGap;
    return span < 0 ? 0 : span;
  }

  /// Builds a diameter profile along the log.
  ///
  /// [seedStart]/[seedEnd] are the user's two taps. They land on the log's
  /// surface, not its centreline, so the axis they imply is tilted; the
  /// axis is refined against the fitted section centres before the final
  /// profile is measured. Skipping that step makes every slice cut the
  /// cylinder obliquely, which over-estimates diameter.
  static LogProfile? buildProfile(
    List<Vector3> cloud,
    Vector3 seedStart,
    Vector3 seedEnd, {
    double slabThicknessMetres = 0.02,
    int refinementIterations = 3,
    double inlierToleranceMetres = 0.01,
    int? seed,
  }) {
    if (cloud.length < 12) return null;

    var axis = _axisFromPoints(seedStart, seedEnd);
    if (axis == null) return null;

    final length = (seedEnd - seedStart).length;
    if (length <= slabThicknessMetres) return null;

    List<CrossSection> sections = const [];
    List<CrossSection> rejected = const [];

    for (var iteration = 0; iteration <= refinementIterations; iteration++) {
      final result = _sliceAndFit(
        cloud,
        axis!,
        length,
        slabThicknessMetres: slabThicknessMetres,
        inlierToleranceMetres: inlierToleranceMetres,
        seed: seed,
      );

      sections = result.accepted;
      rejected = result.rejected;

      if (iteration == refinementIterations) break;
      if (sections.length < 2) break;

      final refined = _fitAxisThroughCentres(sections);
      if (refined == null) break;
      axis = refined;
    }

    if (sections.isEmpty) {
      return LogProfile(
        axis: axis!,
        sections: const [],
        rejectedSections: rejected,
        lengthMetres: length,
      );
    }

    // Length from where surface was actually observed, bounded by the taps.
    final first = sections.first.axialPosition;
    final last = sections.last.axialPosition;
    final observed = (last - first).abs() + slabThicknessMetres;

    return LogProfile(
      axis: axis!,
      sections: sections,
      rejectedSections: rejected,
      lengthMetres: observed > length ? length : observed,
    );
  }

  /// The log's minimum diameter, from a smoothed profile.
  ///
  /// Never a raw `min` of the per-section values: those are noisy estimates,
  /// so the smallest one is whichever section happened to fit worst, biased
  /// downward. Undervaluing a log costs the seller money, so the profile is
  /// median-smoothed first and the minimum taken from that.
  static double? minDiameterFromProfile(
    List<double> diameters, {
    int medianWindow = 3,
  }) {
    if (diameters.isEmpty) return null;
    if (diameters.length < medianWindow || medianWindow < 3) {
      return diameters.reduce((a, b) => a < b ? a : b);
    }

    final half = medianWindow ~/ 2;
    double? smallest;

    for (var i = 0; i < diameters.length; i++) {
      final start = math.max(0, i - half);
      final end = math.min(diameters.length, i + half + 1);

      final window = diameters.sublist(start, end)..sort();
      final median = window[window.length ~/ 2];

      if (smallest == null || median < smallest) smallest = median;
    }

    return smallest;
  }

  // --- internals ----------------------------------------------------------

  static LogAxis? _axisFromPoints(Vector3 start, Vector3 end) {
    final delta = end - start;
    final length = delta.length;

    if (length < 1e-6 || !length.isFinite) return null;

    return LogAxis(origin: start, direction: delta.normalized());
  }

  static ({List<CrossSection> accepted, List<CrossSection> rejected})
      _sliceAndFit(
    List<Vector3> cloud,
    LogAxis axis,
    double length, {
    required double slabThicknessMetres,
    required double inlierToleranceMetres,
    int? seed,
  }) {
    final basis = _perpendicularBasis(axis.direction);

    final slabCount = (length / slabThicknessMetres).floor();
    if (slabCount < 1) return (accepted: const [], rejected: const []);

    // Bucket points by slab in one pass rather than rescanning the cloud
    // per slice.
    final buckets = List.generate(slabCount, (_) => <Vector2>[]);
    final bucketAxial = List<double>.filled(slabCount, 0);

    for (final point in cloud) {
      final relative = point - axis.origin;
      final along = relative.dot(axis.direction);

      if (along < 0 || along >= length) continue;

      final index = (along / slabThicknessMetres).floor();
      if (index < 0 || index >= slabCount) continue;

      final perpendicular = relative - axis.direction * along;

      buckets[index].add(
        Vector2(perpendicular.dot(basis.u), perpendicular.dot(basis.v)),
      );
      bucketAxial[index] = (index + 0.5) * slabThicknessMetres;
    }

    final accepted = <CrossSection>[];
    final rejected = <CrossSection>[];

    double? runningRadius;

    for (var i = 0; i < slabCount; i++) {
      var points = buckets[i];
      if (points.length < 5) continue;

      // Stacked logs: drop anything implausibly far from the axis once we
      // have a sense of this log's size.
      if (runningRadius != null) {
        final limit = runningRadius * radialGateFactor;
        points = points.where((p) => p.length <= limit).toList();
        if (points.length < 5) continue;
      }

      final fit = fitCircleRansac(
        points,
        inlierToleranceMetres: inlierToleranceMetres,
        seed: seed,
      );
      if (fit == null) continue;

      final centre3d = axis.origin +
          axis.direction * bucketAxial[i] +
          basis.u * fit.center.x +
          basis.v * fit.center.y;

      final section = CrossSection(
        axialPosition: bucketAxial[i],
        center: centre3d,
        radius: fit.radius,
        rmsResidual: fit.rmsResidual,
        angularSpanRadians: fit.angularSpanRadians,
        pointCount: fit.pointCount,
      );

      if (fit.angularSpanRadians >= minAngularSpanRadians) {
        accepted.add(section);
        runningRadius = runningRadius == null
            ? fit.radius
            : (runningRadius + fit.radius) / 2;
      } else {
        rejected.add(section);
      }
    }

    return (accepted: accepted, rejected: rejected);
  }

  /// Least-squares 3D line through the fitted section centres, which lie on
  /// the true centreline even when the seed axis was tilted.
  static LogAxis? _fitAxisThroughCentres(List<CrossSection> sections) {
    if (sections.length < 2) return null;

    final centres = sections.map((s) => s.center).toList();

    var mean = Vector3.zero();
    for (final c in centres) {
      mean += c;
    }
    mean = mean / centres.length.toDouble();

    // Principal direction via power iteration on the covariance matrix --
    // enough for a dominant axis, and avoids pulling in a full SVD.
    var direction = (centres.last - centres.first);
    if (direction.length < 1e-9) return null;
    direction = direction.normalized();

    for (var iter = 0; iter < 12; iter++) {
      var next = Vector3.zero();

      for (final c in centres) {
        final d = c - mean;
        next += d * d.dot(direction);
      }

      if (next.length < 1e-12) return null;
      direction = next.normalized();
    }

    // Anchor the axis at the start of the log, keeping the original sense.
    final along = (centres.first - mean).dot(direction);
    final origin = mean + direction * along;

    if ((centres.last - centres.first).dot(direction) < 0) {
      direction = -direction;
    }

    return LogAxis(origin: origin, direction: direction);
  }

  static ({Vector3 u, Vector3 v}) _perpendicularBasis(Vector3 direction) {
    // Pick whichever cardinal axis is least aligned with the direction, so
    // the cross product is never near-degenerate.
    final helper = direction.x.abs() < 0.9
        ? Vector3(1, 0, 0)
        : Vector3(0, 1, 0);

    final u = direction.cross(helper).normalized();
    final v = direction.cross(u).normalized();

    return (u: u, v: v);
  }

  static double _rmsResidual(
    List<Vector2> points,
    Vector2 center,
    double radius,
  ) {
    if (points.isEmpty) return 0;

    var sum = 0.0;
    for (final p in points) {
      final d = (p - center).length - radius;
      sum += d * d;
    }

    return math.sqrt(sum / points.length);
  }

  static ({Vector2 center, double radius})? _circumcircle(
    Vector2 a,
    Vector2 b,
    Vector2 c,
  ) {
    final d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));

    if (d.abs() < 1e-12) return null;

    final aSq = a.x * a.x + a.y * a.y;
    final bSq = b.x * b.x + b.y * b.y;
    final cSq = c.x * c.x + c.y * c.y;

    final ux =
        (aSq * (b.y - c.y) + bSq * (c.y - a.y) + cSq * (a.y - b.y)) / d;
    final uy =
        (aSq * (c.x - b.x) + bSq * (a.x - c.x) + cSq * (b.x - a.x)) / d;

    if (!ux.isFinite || !uy.isFinite) return null;

    final center = Vector2(ux, uy);
    return (center: center, radius: (a - center).length);
  }
}
