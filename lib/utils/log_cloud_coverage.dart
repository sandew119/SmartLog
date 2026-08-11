import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'scan_coverage.dart';

/// Measures how much of a log a point cloud has actually seen.
///
/// The same analysis the native scanner runs during a sweep, in Dart.
///
/// It exists here for two reasons. The first is that the Swift version runs
/// four times a second on a device none of this can be tested on, and the
/// idea it rests on -- that a filled cross-section means a sawn end and a
/// hollow one means the cloud merely stops -- is the linchpin of the whole
/// scan flow. If that discrimination does not hold, the Finish button never
/// enables and the scanner is worse than it was. Proving it against
/// synthetic cylinders is the only verification available off-device.
///
/// The second is that it produces a [ScanProgress] -- exactly what the
/// native payload decodes to -- so a test can drive a cloud through the real
/// [ScanCoverage] decision and assert on what the user would actually see.
class LogCloudCoverage {
  const LogCloudCoverage._();

  /// Sections along the log, and sectors around it, when the cloud is dense
  /// enough to support them. Matches the native constants.
  static const int maxBinCount = 48;
  static const int maxSectorCount = 36;

  /// The coarsest the analysis will go before giving up.
  ///
  /// Below these there is no longer enough resolution for "have I been all
  /// the way round" to mean anything.
  static const int minBinCount = 6;
  static const int minSectorCount = 8;

  /// Sections along the log, chosen from how many points there are.
  ///
  /// Fixed at 48, this was an assumption about density dressed up as a
  /// constant. A section is only judged at all once it holds a sector's
  /// worth of points, so on a sparse cloud every section falls below that,
  /// no section is judged, and angular coverage comes back as zero however
  /// carefully the user walked round. A 10 cm object can yield at most ~300
  /// points -- 6 per section -- so it could never have finished a scan.
  ///
  /// Coarsening is not a lowered standard. The user still has to have been
  /// all the way round and still has to have shown both ends; those facts
  /// are simply judged at a resolution the points can actually support.
  static int binsFor(int pointCount) {
    final affordable =
        pointCount ~/ (minSectorCount * pointsPerSectorFor(pointCount) * 2);

    return affordable.clamp(minBinCount, maxBinCount);
  }

  /// Sectors around the trunk, chosen from how many points a section holds.
  static int sectorsFor(int pointsInSection, int totalPoints) {
    final affordable =
        pointsInSection ~/ (pointsPerSectorFor(totalPoints) * 2);

    return affordable.clamp(minSectorCount, maxSectorCount);
  }

  /// A sector counts as seen once this many points fall in it, so one stray
  /// depth return cannot claim a whole sector was covered.
  static const int minPointsPerSector = 3;

  /// Below this many points the whole cloud is sparse enough that three per
  /// sector is a larger share of it than the rule was ever meant to demand.
  static const int sparseCloudThreshold = 2000;

  /// Points a sector needs before it counts as seen.
  ///
  /// Three on any normal scan. Two when the cloud is sparse, because the
  /// rule exists to stop a single stray return claiming a sector, and two
  /// already does that -- while three, on an object returning twenty points
  /// around its whole circumference, rejects sectors the sensor genuinely
  /// saw and reports a full sweep as half of one.
  static int pointsPerSectorFor(int totalPoints) =>
      totalPoints < sparseCloudThreshold ? 2 : minPointsPerSector;

  static ScanProgress analyse(List<Vector3> points) {
    if (points.length < 100) return const ScanProgress();

    final centroid = _mean(points);
    final axis = _principalAxis(points, centroid);

    // A degenerate axis means the cloud has no dominant direction -- a wall
    // or the ground rather than a log.
    if (axis.length < 0.5) return const ScanProgress();

    final basis = _basisPerpendicularTo(axis);
    final u = basis.$1;
    final v = basis.$2;

    final axial = List<double>.filled(points.length, 0);
    final radii = List<double>.filled(points.length, 0);
    final angles = List<double>.filled(points.length, 0);

    var minT = double.infinity;
    var maxT = double.negativeInfinity;

    for (var i = 0; i < points.length; i++) {
      final offset = points[i] - centroid;

      final t = offset.dot(axis);
      final radial = offset - axis * t;

      axial[i] = t;
      radii[i] = radial.length;
      angles[i] = math.atan2(radial.dot(v), radial.dot(u));

      minT = math.min(minT, t);
      maxT = math.max(maxT, t);
    }

    final length = maxT - minT;
    if (length <= 0.01) return const ScanProgress();

    // --- bin along the axis -------------------------------------------

    final binCount = binsFor(points.length);

    final bins = List.generate(binCount, (_) => <int>[]);

    for (var i = 0; i < points.length; i++) {
      final normalised = (axial[i] - minT) / length;
      final bin = (normalised * binCount).floor().clamp(0, binCount - 1);
      bins[bin].add(i);
    }

    // --- angular coverage, worst interior section ----------------------

    // End sections are skipped: a sawn face is a disc, not a ring, so its
    // angular coverage means nothing. The circle fits that decide the
    // girth happen along the trunk.
    final skip = math.max(1, binCount ~/ 12);

    var worstAngular = 360.0;
    var sawAnySection = false;

    for (var bin = skip; bin < binCount - skip; bin++) {
      final indices = bins[bin];

      final sectorCount = sectorsFor(indices.length, points.length);
      if (indices.length < sectorCount) continue;

      // Angles are measured about this section's own fitted centre, not the
      // cloud's centroid.
      //
      // The centroid of a partial arc sits inside the bulge of that arc, so
      // angles taken from it fan out wider than the arc really is: a 170
      // degree sweep measured 250. Overstating coverage is the dangerous
      // direction -- it lets a thin arc finish a scan, and a circle fitted
      // to a thin arc is exactly what puts centimetres of error into a
      // radius.
      final section = [
        for (final i in indices)
          (
            x: radii[i] * math.cos(angles[i]),
            y: radii[i] * math.sin(angles[i])
          ),
      ];

      final centre = _fitCircleCentre(section);

      final sectors = List<int>.filled(sectorCount, 0);

      for (final p in section) {
        final angle = math.atan2(p.y - centre.y, p.x - centre.x);
        final normalised = (angle / (2 * math.pi) + 0.5).clamp(0.0, 0.9999);
        sectors[(normalised * sectorCount).floor()]++;
      }

      final seen =
          sectors.where((c) => c >= pointsPerSectorFor(points.length)).length;

      worstAngular = math.min(worstAngular, seen * (360 / sectorCount));
      sawAnySection = true;
    }

    return ScanProgress(
      pointCount: points.length,
      axisLengthMetres: length,
      angularCoverageDegrees: sawAnySection ? worstAngular : 0,
      endFillStart: fill(bins.first, radii, angles),
      endFillEnd: fill(bins.last, radii, angles),
      axialBins: [for (final b in bins) b.length],
      radiusMetres: _medianInteriorRadius(bins, radii, skip),
      trackingReliable: true,
    );
  }

  /// A representative radius: the median over interior sections.
  ///
  /// Robust to the end faces, whose points run in towards the axis, and to a
  /// stray return beyond the surface. Mirrors what the native analyser
  /// reports, and is what sizes the point requirement -- an object can only
  /// yield as many points as its surface has room for.
  static double _medianInteriorRadius(
    List<List<int>> bins,
    List<double> radii,
    int skip,
  ) {
    final interior = <double>[];

    for (var bin = skip; bin < bins.length - skip; bin++) {
      for (final i in bins[bin]) {
        interior.add(radii[i]);
      }
    }

    if (interior.isEmpty) return 0;

    interior.sort();

    return interior[interior.length ~/ 2];
  }

  /// Radial rings and sectors the inner disc is divided into when judging
  /// whether a cross-section is a sawn face.
  static const int fillRings = 3;
  static const int fillSectors = 12;

  /// Points needed in a cell before it counts as occupied.
  ///
  /// Occupancy saturates, which is the whole reason it works -- but that also
  /// means a single stray return would claim a whole cell. Real depth data
  /// scatters a few points inside the trunk's silhouette, and thirteen of
  /// them landing in thirteen different cells would read as a sawn end and
  /// let the user finish a scan that never saw one. A real face puts dozens
  /// of points in every cell, so requiring three costs nothing.
  static const int minPointsPerFillCell = 3;

  /// How much of a cross-section's inner disc is occupied, 0..1.
  ///
  /// Along the trunk the sensor only sees the curved surface, so a section's
  /// points sit in a ring at roughly the trunk radius and the middle of the
  /// disc is empty. At a sawn end the whole face is visible at once, so
  /// points fill in towards the axis.
  ///
  /// Measured as the share of *cells* inside half the radius that contain
  /// any points -- not the share of points falling there. Counting points
  /// sounds equivalent and is not: the same bin also holds the ring of
  /// surface points around it, so the figure gets diluted by however much
  /// trunk happens to sit in that section and by how long the user lingered
  /// on the face. A fully-seen cut face measured only 0.18 that way, against
  /// 0.08 for an unscanned end -- far too narrow a gap to threshold on.
  /// Occupancy separates them at roughly 1.0 against 0.0.
  static double fill(
    List<int> indices,
    List<double> radii,
    List<double> angles,
  ) {
    if (indices.length < 20) return 0;

    final sorted = [for (final i in indices) radii[i]]..sort();

    // A high percentile rather than the maximum: one stray point beyond the
    // surface would otherwise set the reference and make every real end
    // look empty.
    final outer =
        sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];
    if (outer <= 0) return 0;

    final limit = outer * 0.5;

    final inner = [for (final i in indices) if (radii[i] < limit) i];

    // The grid is sized to the points there are to put in it.
    //
    // Fixed at 3 rings by 12 sectors, the disc needed 108 points before it
    // could read as full at all -- more than a small object's whole end face
    // returns. It therefore read empty however squarely the user pointed at
    // it, and the scan could never finish. Coarser cells still separate the
    // two cases the measure exists to separate: a sawn face fills whatever
    // grid it is given, and a hollow ring fills none of it.
    // Sized from the whole section, never from the inner points alone.
    //
    // Sizing it from the inner points is self-fulfilling: a handful of stray
    // returns then gets a grid coarse enough for a handful to fill, and
    // reads as a sawn face. Sizing it from how much surface the section
    // holds asks the right question -- is the middle of this disc as
    // populated as the section around it -- and noise cannot pass it.
    final cellBudget = (indices.length ~/ (minPointsPerFillCell * 6))
        .clamp(4, fillRings * fillSectors);

    final rings = cellBudget <= 8 ? 1 : (cellBudget <= 18 ? 2 : fillRings);
    final sectors = math.max(4, cellBudget ~/ rings);

    final cells = List<int>.filled(rings * sectors, 0);

    for (final i in inner) {
      final ring = ((radii[i] / limit) * rings).floor().clamp(0, rings - 1);

      final normalised = (angles[i] / (2 * math.pi) + 0.5).clamp(0.0, 0.9999);
      final sector = (normalised * sectors).floor();

      cells[ring * sectors + sector]++;
    }

    final occupied = cells.where((c) => c >= minPointsPerFillCell).length;

    return occupied / cells.length;
  }

  /// Algebraic (Kasa) circle fit, returning just the centre.
  ///
  /// Linear least squares rather than an iterative geometric fit: the centre
  /// is all that is wanted, it is wanted for every section on every progress
  /// tick, and a fit good to a few millimetres is ample for deciding which
  /// sectors have been seen.
  static ({double x, double y}) _fitCircleCentre(
    List<({double x, double y})> points,
  ) {
    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0;
    var sxz = 0.0, syz = 0.0;

    for (final p in points) {
      final z = p.x * p.x + p.y * p.y;

      sx += p.x;
      sy += p.y;
      sxx += p.x * p.x;
      syy += p.y * p.y;
      sxy += p.x * p.y;
      sxz += p.x * z;
      syz += p.y * z;
    }

    final n = points.length.toDouble();

    final a = 2 * (sx * sx - n * sxx);
    final b = 2 * (sx * sy - n * sxy);
    final c = 2 * (sy * sy - n * syy);

    final d = n * sxz - sx * (sxx + syy);
    final e = n * syz - sy * (sxx + syy);

    final determinant = a * c - b * b;

    // Collinear or degenerate: fall back to the section's own mean, which is
    // no worse than what the code did before this existed.
    if (determinant.abs() < 1e-12) {
      return (x: sx / n, y: sy / n);
    }

    return (
      x: (d * c - b * e) / determinant,
      y: (a * e - d * b) / determinant,
    );
  }

  static Vector3 _mean(List<Vector3> points) {
    var total = Vector3.zero();
    for (final p in points) {
      total += p;
    }
    return total / points.length.toDouble();
  }

  /// The direction the cloud is longest in, by power iteration on the
  /// covariance matrix.
  ///
  /// Power iteration rather than a full eigen-decomposition because only the
  /// largest eigenvector is wanted, and it converges in a handful of steps
  /// for a shape as elongated as a log -- which is exactly the case where
  /// the answer matters.
  static Vector3 _principalAxis(List<Vector3> points, Vector3 centroid) {
    final covariance = Matrix3.zero();

    for (final point in points) {
      final d = point - centroid;

      covariance.add(
        Matrix3(
          d.x * d.x, d.x * d.y, d.x * d.z, //
          d.y * d.x, d.y * d.y, d.y * d.z,
          d.z * d.x, d.z * d.y, d.z * d.z,
        ),
      );
    }

    // Seeded off-axis so a cloud lying along a coordinate axis does not
    // start on an exact eigenvector of the wrong one.
    var vector = Vector3(0.577, 0.577, 0.577)..normalize();

    for (var i = 0; i < 32; i++) {
      final next = covariance * vector as Vector3;
      final magnitude = next.length;

      if (magnitude <= 1e-9) return Vector3.zero();

      vector = next / magnitude;
    }

    return vector;
  }

  /// Two unit vectors spanning the plane across [axis].
  static (Vector3, Vector3) _basisPerpendicularTo(Vector3 axis) {
    // Cross with whichever world axis the log is least aligned to, so the
    // cross product is never near zero.
    final helper = axis.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);

    final u = axis.cross(helper)..normalize();
    final v = axis.cross(u)..normalize();

    return (u, v);
  }
}
