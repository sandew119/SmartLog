import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/log_face_outline.dart';

/// An ellipse, and a robust way to fit one to noisy edge points.
///
/// A log's cut face photographed square-on is a circle; photographed at any
/// angle it is an ellipse. Fitting that shape rather than trusting 72 loose
/// ray hits is what stops one bad reading -- a shadow, a bark flake, a
/// branch stub, the background showing through -- from putting a spike in
/// the outline.
///
/// Pure maths over `Offset`, with no image, camera or widget dependency, so
/// every claim below is unit-testable on a machine with no device.
class Ellipse {
  final Offset centre;

  /// Always the longer of the two semi-axes.
  final double semiMajor;

  /// Always the shorter.
  final double semiMinor;

  /// Angle of the major axis, in radians.
  final double rotation;

  const Ellipse({
    required this.centre,
    required this.semiMajor,
    required this.semiMinor,
    required this.rotation,
  });

  /// When a round face is photographed at an angle, the minor axis is
  /// foreshortened but the major axis still spans the true diameter. So this
  /// -- not the mean of the two -- is the figure to scale from.
  double get trueDiameter => semiMajor * 2;

  double get area => math.pi * semiMajor * semiMinor;

  /// How far from circular, 0 (circle) to 1 (degenerate line).
  double get eccentricityRatio =>
      semiMajor <= 0 ? 0 : 1 - (semiMinor / semiMajor);

  /// Distance from the centre to the boundary along a global-frame [angle].
  double radiusAt(double angle) {
    final local = angle - rotation;
    final c = semiMinor * math.cos(local);
    final s = semiMajor * math.sin(local);

    final denominator = math.sqrt(c * c + s * s);
    if (denominator <= 0) return 0;

    return semiMajor * semiMinor / denominator;
  }

  Offset pointAt(double angle) {
    final r = radiusAt(angle);
    return Offset(
      centre.dx + r * math.cos(angle),
      centre.dy + r * math.sin(angle),
    );
  }

  bool contains(Offset p) {
    final d = p - centre;
    final c = math.cos(rotation);
    final s = math.sin(rotation);

    final u = d.dx * c + d.dy * s;
    final v = -d.dx * s + d.dy * c;

    if (semiMajor <= 0 || semiMinor <= 0) return false;

    final nu = u / semiMajor;
    final nv = v / semiMinor;

    return nu * nu + nv * nv <= 1;
  }

  List<Offset> toPolygon(int count) {
    return List.generate(count, (i) => pointAt(2 * math.pi * i / count));
  }

  LogFaceOutline toOutline({int segments = 72}) =>
      LogFaceOutline(toPolygon(segments));

  Ellipse copyWith({
    Offset? centre,
    double? semiMajor,
    double? semiMinor,
    double? rotation,
  }) {
    return Ellipse(
      centre: centre ?? this.centre,
      semiMajor: semiMajor ?? this.semiMajor,
      semiMinor: semiMinor ?? this.semiMinor,
      rotation: rotation ?? this.rotation,
    );
  }

  @override
  String toString() =>
      "Ellipse(centre: $centre, a: ${semiMajor.toStringAsFixed(2)}, "
      "b: ${semiMinor.toStringAsFixed(2)}, "
      "rot: ${(rotation * 180 / math.pi).toStringAsFixed(1)}deg)";
}

/// Fits an ellipse to [points], ignoring outliers.
///
/// Uses iteratively reweighted least squares with a Tukey biweight rather
/// than the usual direct (Fitzgibbon) conic fit. Fitzgibbon needs a
/// generalised eigen-solve, which in pure Dart means either a matrix library
/// or a fragile hand-rolled one; IRLS reaches the same robustness with a
/// 5x5 linear solve, and being deterministic it can actually be tested --
/// unlike RANSAC, whose answer moves with its random seed.
///
/// Returns null rather than a meaningless ellipse when the points cannot
/// support one: too few, collinear, or the fit diverging.
Ellipse? fitEllipseIrls(
  List<Offset> points, {
  int maxIterations = 30,
  double convergenceEpsilon = 1e-6,
}) {
  // Five free parameters, so five points is the bare algebraic minimum and
  // anything fewer is guesswork dressed up as a measurement.
  if (points.length < 5) return null;

  for (final p in points) {
    if (!p.dx.isFinite || !p.dy.isFinite) return null;
  }

  // Seed from a trimmed set, then refine against all of them.
  //
  // IRLS only converges on the robust answer if it *starts* near one: the
  // weights are judged against the current fit, so a seed wrecked by
  // outliers makes those same outliers look reasonable and nothing ever
  // gets down-weighted. Plain moments are not robust -- a quarter of the
  // rays landing on background is enough to inflate the covariance wildly
  // -- so the seed comes from a median-trimmed subset instead.
  final trimmed = _trimGrossOutliers(points);

  final seed = _initialEllipseFromMoments(trimmed);
  if (seed == null) return null;

  // Nothing plausible can be much larger than the data it was fitted to.
  // Without this a single bad step runs away to an ellipse thousands of
  // units across, which then swallows every outlier and looks converged.
  final sizeLimit = _dataExtent(trimmed) * 3;

  Ellipse current = seed;

  for (var iteration = 0; iteration < maxIterations; iteration++) {
    final next = _gaussNewtonStep(points, current, sizeLimit);
    if (next == null) break;

    final moved = (next.centre - current.centre).distance +
        (next.semiMajor - current.semiMajor).abs() +
        (next.semiMinor - current.semiMinor).abs();

    current = next;

    if (moved < convergenceEpsilon) break;
  }

  if (!_isUsable(current)) return null;

  return _normalised(current);
}

/// Seeds the fit from the point cloud's second moments.
///
/// For points spread evenly around an ellipse, the covariance in the ellipse
/// frame is diag(a^2/2, b^2/2), so the eigenvalues give the axes directly.
/// It is only an approximation -- unevenly sampled points bias it -- but it
/// lands close enough for Gauss-Newton to converge, and it costs one pass.
Ellipse? _initialEllipseFromMoments(List<Offset> points) {
  double meanX = 0, meanY = 0;
  for (final p in points) {
    meanX += p.dx;
    meanY += p.dy;
  }
  meanX /= points.length;
  meanY /= points.length;

  double sxx = 0, syy = 0, sxy = 0;
  for (final p in points) {
    final dx = p.dx - meanX;
    final dy = p.dy - meanY;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  sxx /= points.length;
  syy /= points.length;
  sxy /= points.length;

  // Closed-form eigenvalues of the symmetric 2x2 covariance.
  final trace = sxx + syy;
  final det = sxx * syy - sxy * sxy;
  final discriminant = trace * trace / 4 - det;

  if (!discriminant.isFinite) return null;

  // A symmetric covariance matrix always has real eigenvalues, so the
  // discriminant cannot truly be negative -- but for a perfectly round face
  // it is mathematically *zero*, and floating point lands either side of
  // that by an ulp. Bailing out on the negative side would make the fit
  // succeed or fail on rounding noise for the single most common input
  // there is: a circular log end.
  final root = math.sqrt(math.max(0, discriminant));
  final lambda1 = trace / 2 + root;
  final lambda2 = trace / 2 - root;

  // A vanishing minor eigenvalue means the points lie on a line. There is no
  // ellipse there, and pretending otherwise yields an infinitely thin one.
  if (lambda1 <= 0 || lambda2 <= 1e-9 * lambda1) return null;

  final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);

  return Ellipse(
    centre: Offset(meanX, meanY),
    semiMajor: math.sqrt(2 * lambda1),
    semiMinor: math.sqrt(2 * lambda2),
    rotation: theta,
  );
}

/// Drops points that are nowhere near the bulk of the trace.
///
/// Works on distance from a coordinate-wise median centre, which survives up
/// to half the points being wrong -- unlike the mean, which one stray ray
/// into the background can drag across the image. The cutoff is deliberately
/// loose: on an elongated ellipse the radius legitimately varies between the
/// two semi-axes, and trimming that variation would bias the fit circular.
List<Offset> _trimGrossOutliers(List<Offset> points) {
  if (points.length < 8) return points;

  final xs = [for (final p in points) p.dx]..sort();
  final ys = [for (final p in points) p.dy]..sort();

  final centre = Offset(xs[xs.length ~/ 2], ys[ys.length ~/ 2]);

  final radii = [for (final p in points) (p - centre).distance];
  final sortedRadii = List<double>.from(radii)..sort();
  final medianRadius = sortedRadii[sortedRadii.length ~/ 2];

  if (medianRadius <= 0) return points;

  final deviations = [for (final r in radii) (r - medianRadius).abs()]..sort();
  final mad = deviations[deviations.length ~/ 2];

  // Floor the scale so a perfectly clean circle -- where the MAD is ~0 --
  // does not reject its own points to floating-point noise.
  final scale = math.max(1.4826 * mad, medianRadius * 0.1);

  final kept = <Offset>[
    for (var i = 0; i < points.length; i++)
      if ((radii[i] - medianRadius).abs() <= 3 * scale) points[i],
  ];

  // If trimming took too much, the assumption behind it was wrong; better to
  // fit everything than to fit five survivors.
  return kept.length >= 5 && kept.length >= points.length ~/ 2 ? kept : points;
}

/// Largest distance from the set's centroid -- a scale for sanity checks.
double _dataExtent(List<Offset> points) {
  if (points.isEmpty) return 0;

  double meanX = 0, meanY = 0;
  for (final p in points) {
    meanX += p.dx;
    meanY += p.dy;
  }
  final centre = Offset(meanX / points.length, meanY / points.length);

  double extent = 0;
  for (final p in points) {
    extent = math.max(extent, (p - centre).distance);
  }

  return extent;
}

/// One Gauss-Newton step on (cx, cy, a, b, theta), robustly reweighted.
Ellipse? _gaussNewtonStep(List<Offset> points, Ellipse e, double sizeLimit) {
  final c = math.cos(e.rotation);
  final s = math.sin(e.rotation);

  final a = e.semiMajor;
  final b = e.semiMinor;

  if (a <= 0 || b <= 0) return null;

  // Residuals first, so the robust scale can be measured before weighting.
  final algebraic = List<double>.filled(points.length, 0);
  final geometric = List<double>.filled(points.length, 0);

  for (var i = 0; i < points.length; i++) {
    final dx = points[i].dx - e.centre.dx;
    final dy = points[i].dy - e.centre.dy;

    final u = dx * c + dy * s;
    final v = -dx * s + dy * c;

    final r = (u * u) / (a * a) + (v * v) / (b * b) - 1;
    algebraic[i] = r;

    // Sampson distance: the algebraic residual divided by its gradient with
    // respect to the point. It approximates the true distance in pixels,
    // which is what makes a robust cutoff meaningful -- the raw algebraic
    // residual scales with ellipse size and would tune itself differently
    // for every log.
    final grx = 2 * u * c / (a * a) - 2 * v * s / (b * b);
    final gry = 2 * u * s / (a * a) + 2 * v * c / (b * b);
    final gradient = math.sqrt(grx * grx + gry * gry);

    geometric[i] = gradient > 1e-12 ? (r / gradient).abs() : r.abs();
  }

  final scale = _robustScale(geometric);

  // 5x5 normal equations.
  final jtj = List.generate(5, (_) => List<double>.filled(5, 0));
  final jtr = List<double>.filled(5, 0);

  for (var i = 0; i < points.length; i++) {
    final weight = _tukeyWeight(geometric[i], scale);
    if (weight <= 0) continue;

    final dx = points[i].dx - e.centre.dx;
    final dy = points[i].dy - e.centre.dy;

    final u = dx * c + dy * s;
    final v = -dx * s + dy * c;

    final invA2 = 1 / (a * a);
    final invB2 = 1 / (b * b);

    final jacobian = <double>[
      -2 * u * c * invA2 + 2 * v * s * invB2, // d/dcx
      -2 * u * s * invA2 - 2 * v * c * invB2, // d/dcy
      -2 * u * u / (a * a * a), // d/da
      -2 * v * v / (b * b * b), // d/db
      2 * u * v * (invA2 - invB2), // d/dtheta
    ];

    for (var row = 0; row < 5; row++) {
      jtr[row] += weight * jacobian[row] * algebraic[i];
      for (var col = 0; col < 5; col++) {
        jtj[row][col] += weight * jacobian[row] * jacobian[col];
      }
    }
  }

  // Levenberg damping, scaled to the problem rather than a fixed epsilon.
  //
  // This matters most for the commonest input of all: a nearly round face.
  // Rotation is meaningless for a true circle, so its column of the normal
  // equations collapses to zero -- and with a pixel or two of quantisation
  // it collapses to *almost* zero instead, which is worse. Dividing a tiny
  // residual by a tiny curvature yields an enormous angle step, the axes
  // follow it negative, and the fit is thrown away. A fixed 1e-12 is no
  // defence because it means nothing next to a matrix whose entries run to
  // 1e6; damping proportional to the largest diagonal does, and it drives
  // the rotation step to zero for a circle, which is the right answer.
  var maxDiagonal = 0.0;
  for (var i = 0; i < 5; i++) {
    maxDiagonal = math.max(maxDiagonal, jtj[i][i].abs());
  }

  if (maxDiagonal <= 0 || !maxDiagonal.isFinite) return null;

  final damping = maxDiagonal * 1e-6;
  for (var i = 0; i < 5; i++) {
    jtj[i][i] += damping;
  }

  final delta = _solve5x5(jtj, jtr);
  if (delta == null) return null;

  final candidate = Ellipse(
    centre: Offset(e.centre.dx - delta[0], e.centre.dy - delta[1]),
    semiMajor: a - delta[2],
    semiMinor: b - delta[3],
    rotation: e.rotation - delta[4],
  );

  if (!_isUsable(candidate)) return null;

  // Reject a runaway step rather than following it. Returning null keeps the
  // last good ellipse instead of letting one bad iteration grow a shape big
  // enough to enclose every outlier and then look converged.
  if (sizeLimit > 0 &&
      (candidate.semiMajor > sizeLimit || candidate.semiMinor > sizeLimit)) {
    return null;
  }

  return candidate;
}

/// Median absolute deviation, rescaled to be comparable with a standard
/// deviation. Used as the robust cutoff so the weighting adapts to how noisy
/// this particular trace was instead of relying on a fixed pixel threshold.
double _robustScale(List<double> residuals) {
  if (residuals.isEmpty) return 1;

  final sorted = List<double>.from(residuals)..sort();
  final median = sorted[sorted.length ~/ 2];

  final deviations = residuals.map((r) => (r - median).abs()).toList()..sort();
  final mad = deviations[deviations.length ~/ 2];

  // Floored against the median residual, not just an absolute epsilon.
  //
  // MAD only measures scale when the residuals actually vary. When the fit
  // is uniformly off -- every point the same small distance out, which is
  // exactly what a slightly-wrong radius on a round face produces -- the MAD
  // collapses to zero, every point then looks like a gross outlier, every
  // weight goes to zero, and the step degenerates. Keeping the scale tied to
  // the typical residual stops a systematic offset being mistaken for 100%
  // outliers.
  return math.max(
    math.max(1.4826 * mad, median.abs() * 0.5),
    1e-9,
  );
}

double _tukeyWeight(double residual, double scale) {
  // 4.685 is the standard Tukey tuning constant: ~95% efficiency on clean
  // Gaussian noise while fully rejecting gross outliers.
  const tuning = 4.685;

  final normalised = residual / (tuning * scale);
  if (normalised >= 1) return 0;

  final t = 1 - normalised * normalised;
  return t * t;
}

/// Gaussian elimination with partial pivoting. Returns null on singularity
/// rather than emitting infinities that would silently poison the fit.
List<double>? _solve5x5(List<List<double>> matrix, List<double> rhs) {
  const n = 5;

  final a = [
    for (var i = 0; i < n; i++) [...matrix[i], rhs[i]],
  ];

  for (var col = 0; col < n; col++) {
    var pivotRow = col;
    for (var row = col + 1; row < n; row++) {
      if (a[row][col].abs() > a[pivotRow][col].abs()) pivotRow = row;
    }

    if (a[pivotRow][col].abs() < 1e-15) return null;

    if (pivotRow != col) {
      final tmp = a[pivotRow];
      a[pivotRow] = a[col];
      a[col] = tmp;
    }

    for (var row = col + 1; row < n; row++) {
      final factor = a[row][col] / a[col][col];
      if (factor == 0) continue;

      for (var k = col; k <= n; k++) {
        a[row][k] -= factor * a[col][k];
      }
    }
  }

  final solution = List<double>.filled(n, 0);
  for (var row = n - 1; row >= 0; row--) {
    var sum = a[row][n];
    for (var col = row + 1; col < n; col++) {
      sum -= a[row][col] * solution[col];
    }
    solution[row] = sum / a[row][row];
  }

  for (final value in solution) {
    if (!value.isFinite) return null;
  }

  return solution;
}

bool _isUsable(Ellipse e) {
  return e.centre.dx.isFinite &&
      e.centre.dy.isFinite &&
      e.semiMajor.isFinite &&
      e.semiMinor.isFinite &&
      e.rotation.isFinite &&
      e.semiMajor > 0 &&
      e.semiMinor > 0;
}

/// Gauss-Newton can end with the axes swapped or the angle wound past a
/// half-turn. Both describe the same ellipse, but callers reading
/// `semiMajor` as "the long one" would be misled, so it is fixed here once.
Ellipse _normalised(Ellipse e) {
  var a = e.semiMajor;
  var b = e.semiMinor;
  var rotation = e.rotation;

  if (b > a) {
    final swap = a;
    a = b;
    b = swap;
    rotation += math.pi / 2;
  }

  // An ellipse is symmetric under a half-turn, so fold into [0, pi).
  rotation = rotation % math.pi;
  if (rotation < 0) rotation += math.pi;

  return Ellipse(
    centre: e.centre,
    semiMajor: a,
    semiMinor: b,
    rotation: rotation,
  );
}
