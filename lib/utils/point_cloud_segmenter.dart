import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Isolates the one log the user tapped from everything else the sensor saw.
///
/// A depth frame of a log in a yard contains the ground it rests on, the
/// logs either side of it, and whatever is behind. Fitting circles to that
/// mixture is what makes a scan read wrong: ground points sit inside the
/// slab as a flat sheet and drag the fitted radius out.
///
/// Two stages, both pure Dart so they can be tested against synthetic scenes
/// without a device:
///
///  1. find and drop the ground plane, then
///  2. flood-fill outwards from the user's tap, so only surface actually
///     connected to the tapped log survives.
///
/// Units are metres throughout.

/// A plane in Hessian normal form: points satisfying `normal · p = offset`.
class PlaneFit {
  final Vector3 normal;
  final double offset;
  final int inlierCount;

  const PlaneFit({
    required this.normal,
    required this.offset,
    required this.inlierCount,
  });

  /// Signed distance from the plane. Positive is along the normal.
  double distanceTo(Vector3 point) => point.dot(normal) - offset;
}

class SegmentedLog {
  /// Surface belonging to the tapped log.
  final List<Vector3> points;

  /// The ground that was removed, if one was found. Kept so the UI can say
  /// "I found the ground" rather than silently discarding a third of the
  /// scan.
  final PlaneFit? ground;

  /// Points that survived ground removal but were not connected to the tap
  /// -- neighbouring logs, mostly.
  final int rejectedCount;

  const SegmentedLog({
    required this.points,
    required this.ground,
    required this.rejectedCount,
  });

  bool get isEmpty => points.isEmpty;
}

class PointCloudSegmenter {
  /// Points within this of the fitted plane count as ground. Generous
  /// enough to swallow gravel and tyre ruts.
  static const double defaultGroundToleranceMetres = 0.03;

  /// Two points closer than this are treated as the same surface.
  ///
  /// ARKit's depth map samples roughly every 5-10 mm at working range, so
  /// this is an order of magnitude looser than it needs to be for a clean
  /// scan. That headroom is the point: dark or wet bark drops samples, and
  /// the fill has to bridge those holes or a log comes back in pieces. It is
  /// still far tighter than the gap between two logs lying side by side.
  static const double defaultConnectionRadiusMetres = 0.08;

  /// A plane must account for at least this share of the cloud before it is
  /// believed to be the ground.
  ///
  /// Set well above a token fraction on purpose. A plane laid tangentially
  /// along a log's lower flank collects a surprising number of inliers --
  /// measured at about a fifth of a bare log's points -- and removing it
  /// would eat the bottom of the very log being measured. Ground that is
  /// genuinely there fills far more of the view than that.
  static const double defaultMinGroundFraction = 0.30;

  /// How far from vertical a plane's normal may sit and still be ground.
  static const double defaultMaxGroundTiltDegrees = 25;

  /// At most this share of the cloud may lie *beneath* a plane for it to be
  /// the ground.
  ///
  /// Without this test the algorithm finds the top of the log: the crown of
  /// a cylinder is locally flat and horizontal, easily covering a fifth of
  /// the visible arc. Removing it would delete the very surface the girth is
  /// measured from. Real ground, by contrast, has almost nothing below it.
  static const double defaultMaxBelowFraction = 0.10;

  /// How many points a RANSAC hypothesis is scored against.
  ///
  /// Scoring every point of an accumulated sweep on each of 200 iterations
  /// is millions of distance computations for an answer a random subset
  /// settles just as well: the ground is a large fraction of the cloud, so
  /// a few thousand samples estimate its inlier share to well within the
  /// margin that decides between candidate planes. The winning plane is
  /// then re-scored against everything, so the reported inlier count and
  /// the removal itself stay exact.
  static const int ransacScoreSampleSize = 4000;

  /// The ground must be a *sheet*, not a strip: its inliers have to spread
  /// this far in their narrower in-plane direction.
  ///
  /// A plane tilted along a log grazes its lower flank and can collect a
  /// respectable number of inliers in a band whose width scales with the
  /// log -- measured at 0.28 m on a 0.30 m log. The threshold therefore has
  /// to sit above log-diameter scale, not at it: ground seen behind a log
  /// is metres across in both directions.
  static const double defaultMinGroundExtentMetres = 0.60;

  /// Finds the ground plane, if the scene has one.
  ///
  /// Constrained to planes that are roughly perpendicular to [up]: without
  /// that, RANSAC will happily "find" the flat face of a wall, or the log's
  /// own sawn end, and delete the very surface being measured.
  static PlaneFit? findGroundPlane(
    List<Vector3> cloud, {
    Vector3? up,
    double toleranceMetres = defaultGroundToleranceMetres,
    double maxTiltDegrees = defaultMaxGroundTiltDegrees,
    double minInlierFraction = defaultMinGroundFraction,
    double maxBelowFraction = defaultMaxBelowFraction,
    double minExtentMetres = defaultMinGroundExtentMetres,
    int iterations = 200,
    int? seed,
  }) {
    if (cloud.length < 16) return null;

    // ARKit runs gravity-aligned, so +Y is up unless a caller says otherwise.
    final upDirection = (up ?? Vector3(0, 1, 0)).normalized();
    final minCosine = math.cos(maxTiltDegrees * math.pi / 180);
    final required = (cloud.length * minInlierFraction).ceil();

    final random = math.Random(seed ?? 4242);

    // Deterministic stride rather than random picks, so the sample spans the
    // whole scene instead of clumping, and so a given cloud always scores
    // the same way -- a measurement that changed between runs would be
    // impossible to audit.
    final scoringSet = cloud.length <= ransacScoreSampleSize
        ? cloud
        : [
            for (var i = 0;
                i < cloud.length;
                i += (cloud.length / ransacScoreSampleSize).ceil())
              cloud[i],
          ];

    PlaneFit? best;

    for (var i = 0; i < iterations; i++) {
      final a = cloud[random.nextInt(cloud.length)];
      final b = cloud[random.nextInt(cloud.length)];
      final c = cloud[random.nextInt(cloud.length)];

      var normal = (b - a).cross(c - a);
      final length = normal.length;
      if (length < 1e-9 || !length.isFinite) continue;

      normal = normal / length;

      // Orient consistently upwards so the tilt test and the "keep what is
      // above" test below both mean what they say.
      if (normal.dot(upDirection) < 0) normal = -normal;

      if (normal.dot(upDirection) < minCosine) continue;

      final offset = normal.dot(a);

      var inliers = 0;
      var below = 0;

      for (final p in scoringSet) {
        final distance = p.dot(normal) - offset;

        if (distance.abs() <= toleranceMetres) {
          inliers++;
        } else if (distance < 0) {
          below++;
        }
      }

      // The ground has the scene standing on it, not hanging under it.
      if (below > scoringSet.length * maxBelowFraction) continue;

      if (best == null || inliers > best.inlierCount) {
        best = PlaneFit(normal: normal, offset: offset, inlierCount: inliers);
      }
    }

    if (best == null) return null;

    // Re-score the winner against the whole cloud. The search above works on
    // a sample for speed, but the count that decides whether this really is
    // the ground -- and everything downstream that trusts it -- must be the
    // true one.
    if (scoringSet.length != cloud.length) {
      var exact = 0;
      for (final p in cloud) {
        if (best.distanceTo(p).abs() <= toleranceMetres) exact++;
      }

      best = PlaneFit(
        normal: best.normal,
        offset: best.offset,
        inlierCount: exact,
      );
    }

    if (best.inlierCount < required) return null;
    if (!_spreadsLikeASheet(
      cloud,
      best,
      toleranceMetres: toleranceMetres,
      minExtentMetres: minExtentMetres,
    )) {
      return null;
    }

    return best;
  }

  /// Whether a plane's inliers spread out in both in-plane directions.
  ///
  /// Measured as the spread about the mean along two perpendicular in-plane
  /// axes, so a long thin band scores low on its narrow axis however many
  /// points it contains.
  static bool _spreadsLikeASheet(
    List<Vector3> cloud,
    PlaneFit plane, {
    required double toleranceMetres,
    required double minExtentMetres,
  }) {
    final helper = plane.normal.x.abs() < 0.9
        ? Vector3(1, 0, 0)
        : Vector3(0, 1, 0);

    final u = plane.normal.cross(helper).normalized();
    final v = plane.normal.cross(u).normalized();

    var sumU = 0.0, sumV = 0.0, count = 0;

    for (final p in cloud) {
      if (plane.distanceTo(p).abs() > toleranceMetres) continue;

      sumU += p.dot(u);
      sumV += p.dot(v);
      count++;
    }

    if (count < 3) return false;

    final meanU = sumU / count;
    final meanV = sumV / count;

    var varianceU = 0.0, varianceV = 0.0;

    for (final p in cloud) {
      if (plane.distanceTo(p).abs() > toleranceMetres) continue;

      final du = p.dot(u) - meanU;
      final dv = p.dot(v) - meanV;

      varianceU += du * du;
      varianceV += dv * dv;
    }

    // Two standard deviations is a fair stand-in for the usable width, and
    // unlike a min/max extent it is not decided by a single stray point.
    final spreadU = 2 * math.sqrt(varianceU / count);
    final spreadV = 2 * math.sqrt(varianceV / count);

    return math.min(spreadU, spreadV) >= minExtentMetres;
  }

  /// Flood-fills outwards from [seed] through points that touch.
  ///
  /// This is what makes tapping a log mean something: the log the user
  /// pointed at is one connected surface, and the log beside it is a
  /// separate one with a gap between.
  static List<Vector3> growFromSeed(
    List<Vector3> cloud,
    Vector3 seed, {
    double connectionRadiusMetres = defaultConnectionRadiusMetres,
    double maxSeedDistanceMetres = 0.25,
  }) {
    if (cloud.isEmpty) return const [];

    final cell = connectionRadiusMetres;
    final radiusSquared = connectionRadiusMetres * connectionRadiusMetres;

    // Spatial hash so neighbour lookup is a handful of bucket probes rather
    // than a scan of the whole cloud per point.
    final grid = <(int, int, int), List<int>>{};

    (int, int, int) keyOf(Vector3 p) => (
          (p.x / cell).floor(),
          (p.y / cell).floor(),
          (p.z / cell).floor(),
        );

    for (var i = 0; i < cloud.length; i++) {
      grid.putIfAbsent(keyOf(cloud[i]), () => <int>[]).add(i);
    }

    // Start from the cloud point nearest the tap: the tap is a raycast onto
    // the surface and will not coincide exactly with a sample.
    var startIndex = -1;
    var startDistance = double.infinity;

    for (var i = 0; i < cloud.length; i++) {
      final d = (cloud[i] - seed).length2;
      if (d < startDistance) {
        startDistance = d;
        startIndex = i;
      }
    }

    if (startIndex < 0) return const [];
    if (startDistance > maxSeedDistanceMetres * maxSeedDistanceMetres) {
      return const [];
    }

    final visited = List<bool>.filled(cloud.length, false);
    final queue = <int>[startIndex];
    visited[startIndex] = true;

    final result = <Vector3>[];

    while (queue.isNotEmpty) {
      final index = queue.removeLast();
      final point = cloud[index];
      result.add(point);

      final key = keyOf(point);

      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dz = -1; dz <= 1; dz++) {
            final bucket =
                grid[(key.$1 + dx, key.$2 + dy, key.$3 + dz)];
            if (bucket == null) continue;

            for (final candidate in bucket) {
              if (visited[candidate]) continue;
              if ((cloud[candidate] - point).length2 > radiusSquared) continue;

              visited[candidate] = true;
              queue.add(candidate);
            }
          }
        }
      }
    }

    return result;
  }

  /// Full pipeline: drop the ground, then keep only what the tap is
  /// connected to.
  static SegmentedLog segment(
    List<Vector3> cloud,
    Vector3 seed, {
    Vector3? up,
    double groundToleranceMetres = defaultGroundToleranceMetres,
    double connectionRadiusMetres = defaultConnectionRadiusMetres,
    double minGroundFraction = defaultMinGroundFraction,
    int? seedValue,
  }) {
    if (cloud.isEmpty) {
      return const SegmentedLog(
        points: [],
        ground: null,
        rejectedCount: 0,
      );
    }

    final ground = findGroundPlane(
      cloud,
      up: up,
      toleranceMetres: groundToleranceMetres,
      minInlierFraction: minGroundFraction,
      seed: seedValue,
    );

    List<Vector3> standing = cloud;

    if (ground != null) {
      // Keep only what sits above the ground. Dropping by absolute distance
      // instead would also delete anything the sensor saw *below* it through
      // a gap, and those points are noise.
      standing = cloud
          .where((p) => ground.distanceTo(p) > groundToleranceMetres)
          .toList(growable: false);
    }

    if (standing.isEmpty) {
      return SegmentedLog(
        points: const [],
        ground: ground,
        rejectedCount: cloud.length,
      );
    }

    final grown = growFromSeed(
      standing,
      seed,
      connectionRadiusMetres: connectionRadiusMetres,
    );

    return SegmentedLog(
      points: grown,
      ground: ground,
      rejectedCount: standing.length - grown.length,
    );
  }
}
