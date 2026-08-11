import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// The tolerances the measurement pipeline should use for *this* object.
///
/// Every distance in the geometry pipeline is a judgement about scale. How
/// far apart may two points be and still belong to the same surface? How far
/// off a fitted circle may a point sit and still be an inlier? How thick
/// should a cross-sectional slab be?
///
/// Those were fixed constants, chosen for a log about 30 cm thick and 3 m
/// long. Applied to a small cylinder they are not merely imprecise, they are
/// the wrong question: an 8 cm flood-fill radius on a 6 cm object bridges
/// straight onto the table it is standing on, so the thing being measured
/// includes the furniture. A 1 cm circle-fit tolerance is a third of a 3 cm
/// radius, which admits almost anything as an inlier and fits a circle to
/// noise.
///
/// So the tolerances are derived instead: first from how densely the sensor
/// actually sampled the scene, then -- once a first pass has an idea how big
/// the object is -- from the object itself. A log and a mug are then measured
/// by the same code at the tolerances each deserves.
class MeasurementScale {
  /// Typical distance between neighbouring returns, in metres.
  ///
  /// The sensor's own resolution at the range the user chose to stand at.
  /// Everything about connectivity follows from this: a gap can only be a
  /// real gap if it is large compared with how finely the surface was
  /// sampled in the first place.
  final double sampleSpacingMetres;

  /// Two points closer than this belong to the same surface.
  final double connectionRadiusMetres;

  /// Points within this of the fitted plane count as ground.
  final double groundToleranceMetres;

  /// How far the ground's inliers must spread before the plane is believed.
  ///
  /// The test exists to stop a plane grazing the object's own lower flank
  /// from passing as the floor, and the width of such a plane scales with
  /// the object -- so the threshold has to as well.
  final double minGroundExtentMetres;

  /// How far off a fitted circle a point may sit and still be an inlier.
  final double inlierToleranceMetres;

  /// Thickness of each cross-sectional slab along the axis.
  final double slabThicknessMetres;

  /// The object's radius, once a first pass has estimated one.
  final double? objectRadiusMetres;

  /// The object's length, once a first pass has estimated one.
  final double? objectLengthMetres;

  const MeasurementScale({
    required this.sampleSpacingMetres,
    required this.connectionRadiusMetres,
    required this.groundToleranceMetres,
    required this.minGroundExtentMetres,
    required this.inlierToleranceMetres,
    required this.slabThicknessMetres,
    this.objectRadiusMetres,
    this.objectLengthMetres,
  });

  /// True once the scale has been anchored on a measured object rather than
  /// on sampling density alone.
  bool get isRefined => objectRadiusMetres != null;

  // --- bounds -----------------------------------------------------------
  //
  // Every derived tolerance is clamped. The upper bounds are the values the
  // pipeline used to hardcode, so a full-size log in a yard is measured
  // exactly as it was before -- this change can only tighten, never loosen.
  // The lower bounds are the sensor's own noise floor: ARKit's depth is good
  // to a few millimetres at working range, and a tolerance below that would
  // reject real surface points as outliers.

  /// Below this a "tolerance" is finer than the sensor can see.
  static const double sensorNoiseFloorMetres = 0.002;

  static const double maxConnectionRadiusMetres = 0.08;
  static const double maxInlierToleranceMetres = 0.01;
  static const double maxSlabThicknessMetres = 0.02;
  static const double maxGroundToleranceMetres = 0.03;
  static const double maxGroundExtentMetres = 0.60;

  /// How many sample spacings apart two points may be and still be joined.
  ///
  /// The flood fill has to bridge dropped returns -- dark or wet bark
  /// swallows infrared and leaves holes -- so it cannot be as tight as the
  /// sampling itself. Six spans a run of five missing samples, which covers
  /// the holes seen in practice without reaching across a real gap.
  static const double connectionSpacings = 6;

  /// Aim for roughly this many cross-sections along the object.
  ///
  /// Enough that the thin end is genuinely found rather than averaged away,
  /// few enough that each slab still holds the points to fit a circle. The
  /// old fixed 2 cm slab gave 150 sections on a 3 m log and 10 on a 20 cm
  /// one; this gives both a working number.
  static const int targetSectionCount = 60;

  /// How many points around the tap the sampling density is judged from.
  ///
  /// A rank rather than a radius, deliberately: picking "everything within
  /// x metres of the tap" would mean choosing a distance, which is the very
  /// assumption this class exists to remove.
  static const int neighbourhoodSize = 2000;

  /// First estimate, from sampling density alone.
  ///
  /// Nothing here assumes anything about how big the object is -- that is
  /// the whole point, since at this stage the object has not been separated
  /// from the scene yet.
  ///
  /// [near] is the user's tap. Density is judged in its neighbourhood rather
  /// than over the whole scene, because the scene is mostly not the object:
  /// a small cylinder on a table contributes a couple of thousand points
  /// against the table's ten thousand, so a median taken over everything is
  /// a measurement of the furniture's sampling, not the object's.
  factory MeasurementScale.fromCloud(List<Vector3> cloud, {Vector3? near}) {
    final spacing = estimateSampleSpacing(
      near == null ? cloud : _nearest(cloud, near, neighbourhoodSize),
    );

    // The ground has to be a wide sheet, or a plane laid along the object's
    // own flank passes for the floor. "Wide" was a flat 60 cm, which a
    // timber yard always clears and a desk never does -- so scanning a small
    // object on a table found no ground at all, left the table in the cloud,
    // and the flood fill walked straight from the object onto it.
    //
    // Judged instead against the size of the scene the sensor was shown,
    // which needs no assumption about the object: real ground fills a good
    // part of the view whatever is standing on it.
    final sceneExtent = _diagonal(cloud);

    return MeasurementScale(
      sampleSpacingMetres: spacing,
      connectionRadiusMetres: (spacing * connectionSpacings)
          .clamp(sensorNoiseFloorMetres * 5, maxConnectionRadiusMetres),
      // Ground tolerance has to swallow the roughness of whatever the object
      // is standing on, but every millimetre of it is also sliced off the
      // bottom of the object. At 3 cm -- the old fixed value -- a 2.5 cm
      // cylinder is decapitated: what survives is a sliver too thin to find
      // an axis through, and the scan returns nothing at all.
      //
      // Three sample spacings is enough to cover a surface the sensor
      // resolves as flat, and scales up on a coarser outdoor scan where the
      // ground really is rough.
      groundToleranceMetres: (spacing * 3)
          .clamp(sensorNoiseFloorMetres * 2, maxGroundToleranceMetres),
      minGroundExtentMetres:
          (sceneExtent * 0.2).clamp(0.10, maxGroundExtentMetres),
      inlierToleranceMetres: (spacing * 3)
          .clamp(sensorNoiseFloorMetres, maxInlierToleranceMetres),
      slabThicknessMetres: maxSlabThicknessMetres,
    );
  }

  /// Second estimate, anchored on what the first pass actually measured.
  ///
  /// [radiusMetres] and [lengthMetres] come from a rough profile built with
  /// the unanchored tolerances above. They do not need to be accurate -- they
  /// only need to be the right order of magnitude, which even a contaminated
  /// first pass gets right.
  MeasurementScale refinedFor({
    required double radiusMetres,
    required double lengthMetres,
  }) {
    if (!radiusMetres.isFinite ||
        !lengthMetres.isFinite ||
        radiusMetres <= 0 ||
        lengthMetres <= 0) {
      return this;
    }

    return MeasurementScale(
      sampleSpacingMetres: sampleSpacingMetres,

      // Never reach further than a fraction of the object's own radius. This
      // is the bound that stops a small object being welded to the surface
      // it rests on: whatever the sampling suggests, a fill that can step
      // half a radius at a time will leave the object before it has finished
      // covering it.
      connectionRadiusMetres: math.min(
        connectionRadiusMetres,
        math.max(radiusMetres * 0.5, sampleSpacingMetres * 2),
      ),

      groundToleranceMetres: math.min(
        groundToleranceMetres,
        math.max(radiusMetres * 0.2, sensorNoiseFloorMetres * 2),
      ),

      // The ground must be a sheet wider than the object is thick, so a
      // plane laid along the object's flank cannot pass for it. Four
      // diameters, floored so a tiny object does not accept a tiny plane.
      minGroundExtentMetres: (radiusMetres * 8).clamp(0.15, maxGroundExtentMetres),

      // A proportion of the radius, not an absolute distance. Six per cent
      // is roughly what 1 cm was on the 17 cm-radius log the constant was
      // chosen for, so a real log is unaffected and a small one stops
      // admitting a third of its own width as inlier slack.
      inlierToleranceMetres: _between(
        radiusMetres * 0.06,
        math.max(sensorNoiseFloorMetres, sampleSpacingMetres),
        maxInlierToleranceMetres,
      ),

      // Slabs sized so the object gets a workable number of sections
      // whatever its length, floored so a slab always spans several samples.
      slabThicknessMetres: _between(
        lengthMetres / targetSectionCount,
        math.max(sampleSpacingMetres * 2, 0.004),
        maxSlabThicknessMetres,
      ),

      objectRadiusMetres: radiusMetres,
      objectLengthMetres: lengthMetres,
    );
  }

  /// Median distance from a point to its nearest neighbour, in metres.
  ///
  /// Computed on a spatial hash rather than by comparing every pair: a sweep
  /// returns tens of thousands of points and the exhaustive form is hundreds
  /// of millions of distance computations for a number a sample settles just
  /// as well.
  ///
  /// The grid starts fine and coarsens until enough sampled points have
  /// found a neighbour, so no cell size has to be assumed in advance -- which
  /// matters, because assuming a distance is the very mistake this class
  /// exists to undo.
  static double estimateSampleSpacing(
    List<Vector3> cloud, {
    int sampleSize = 500,
  }) {
    if (cloud.length < 2) return sensorNoiseFloorMetres;

    var minimum = Vector3.all(double.infinity);
    var maximum = Vector3.all(double.negativeInfinity);

    for (final p in cloud) {
      minimum = Vector3(
        math.min(minimum.x, p.x),
        math.min(minimum.y, p.y),
        math.min(minimum.z, p.z),
      );
      maximum = Vector3(
        math.max(maximum.x, p.x),
        math.max(maximum.y, p.y),
        math.max(maximum.z, p.z),
      );
    }

    final diagonal = (maximum - minimum).length;
    if (!diagonal.isFinite || diagonal <= 0) return sensorNoiseFloorMetres;

    // Sampled with a stride so the estimate spans the whole object rather
    // than clustering wherever the list happens to start, and so a given
    // cloud always yields the same answer.
    final stride = math.max(1, cloud.length ~/ sampleSize);

    var cell = diagonal / 200;

    for (var attempt = 0; attempt < 8; attempt++) {
      final grid = <int, List<Vector3>>{};

      for (final p in cloud) {
        grid.putIfAbsent(_key(p, cell), () => <Vector3>[]).add(p);
      }

      final distances = <double>[];
      var probed = 0;

      for (var i = 0; i < cloud.length; i += stride) {
        probed++;
        final nearest = _nearestNeighbour(cloud[i], grid, cell);
        if (nearest != null) distances.add(nearest);
      }

      // Half the probes finding a neighbour is enough for a median to mean
      // something; below that the grid is too fine to be informative.
      if (distances.length >= math.max(8, probed ~/ 2)) {
        distances.sort();
        final median = distances[distances.length ~/ 2];

        // Returned as measured, not floored. The floor belongs on the
        // derived tolerances, where it stops a tolerance falling below what
        // the sensor can resolve; applying it here instead would report a
        // finely-sampled close-up scan as coarser than it is.
        if (median.isFinite && median > 0) return median;
      }

      cell *= 2;
    }

    return sensorNoiseFloorMetres;
  }

  /// [value] confined to [low]..[high], tolerating a floor above the ceiling.
  ///
  /// The floors here are derived from sampling density and the ceilings are
  /// the pipeline's historical fixed values, so a scan taken from far enough
  /// away -- coarse sampling -- can produce a floor above its own ceiling.
  /// `clamp` throws on that, which would abort a measurement the user is
  /// standing there waiting for.
  ///
  /// The ceiling wins. It is the value the field has always run at, and a
  /// tolerance wider than that has never been needed however coarse the scan.
  static double _between(double value, double low, double high) =>
      value.clamp(math.min(low, high), high).toDouble();

  /// Diagonal of the cloud's bounding box, in metres.
  static double _diagonal(List<Vector3> cloud) {
    if (cloud.isEmpty) return 0;

    var minimum = Vector3.all(double.infinity);
    var maximum = Vector3.all(double.negativeInfinity);

    for (final p in cloud) {
      minimum = Vector3(
        math.min(minimum.x, p.x),
        math.min(minimum.y, p.y),
        math.min(minimum.z, p.z),
      );
      maximum = Vector3(
        math.max(maximum.x, p.x),
        math.max(maximum.y, p.y),
        math.max(maximum.z, p.z),
      );
    }

    final diagonal = (maximum - minimum).length;

    return diagonal.isFinite ? diagonal : 0;
  }

  /// The [count] points closest to [origin].
  static List<Vector3> _nearest(
    List<Vector3> cloud,
    Vector3 origin,
    int count,
  ) {
    if (cloud.length <= count) return cloud;

    final ordered = [...cloud]..sort(
        (a, b) =>
            (a - origin).length2.compareTo((b - origin).length2),
      );

    return ordered.sublist(0, count);
  }

  static int _key(Vector3 p, double cell) {
    final x = (p.x / cell).floor();
    final y = (p.y / cell).floor();
    final z = (p.z / cell).floor();

    return Object.hash(x, y, z);
  }

  /// Distance to the closest other point, searching the 27 cells around
  /// [point]. Null when the neighbourhood holds nothing but the point itself.
  static double? _nearestNeighbour(
    Vector3 point,
    Map<int, List<Vector3>> grid,
    double cell,
  ) {
    var best = double.infinity;

    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dz = -1; dz <= 1; dz++) {
          final neighbours = grid[_key(
            Vector3(
              point.x + dx * cell,
              point.y + dy * cell,
              point.z + dz * cell,
            ),
            cell,
          )];

          if (neighbours == null) continue;

          for (final other in neighbours) {
            final d = (other - point).length;

            // Strictly positive: a point always finds itself at zero, and
            // duplicate returns at the same coordinate say nothing about
            // how finely the surface was sampled.
            if (d > 1e-9 && d < best) best = d;
          }
        }
      }
    }

    return best.isFinite ? best : null;
  }
}
