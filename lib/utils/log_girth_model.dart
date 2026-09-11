import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'depth_frame.dart';
import 'face_scan.dart';

/// One reading of how wide the trunk is at one place along it.
///
/// Worked out from the two rays that just graze the log's edges, not from
/// the points nearest those edges. See [TrunkProfiler] for why the difference
/// is nearly a tenth of the girth.
class TrunkWidthSample {
  /// Where along the log this was taken, in metres from the near face. Kept
  /// alongside [centre] so it can be recomputed once the far end is known
  /// and the axis is no longer a guess.
  final double axialPosition;

  final double widthMetres;

  /// The world direction the width was measured across: at right angles to
  /// both the log and the line of sight.
  final Vector3 lateral;

  /// Where in the world this slice sat, so its position along the log can be
  /// restated against a better axis later.
  final Vector3 centre;

  const TrunkWidthSample({
    required this.axialPosition,
    required this.widthMetres,
    required this.lateral,
    required this.centre,
  });

  TrunkWidthSample restatedAgainst({
    required Vector3 origin,
    required Vector3 axis,
  }) {
    return TrunkWidthSample(
      axialPosition: (centre - origin).dot(axis),
      widthMetres: widthMetres,
      lateral: lateral,
      centre: centre,
    );
  }
}

/// Reads the width of the trunk out of a depth frame, while the user walks
/// the length of the log.
///
/// **Why the width comes from rays and not from points.** From a phone at a
/// normal distance you never see half of a round log -- only the part inside
/// the two lines of sight that just touch it. And the last depth pixel that
/// lands on the log sits some way inside even that, because near the edge
/// the surface is racing away from the camera and a single pixel step skips
/// a long way round the curve. Measured from the outermost *points*, a 30 cm
/// trunk seen from 80 cm comes back 27 cm across: a tenth short, which is a
/// fifth short on the volume.
///
/// The grazing rays themselves carry the right answer. Both are tangent to
/// the log, so if they meet at the camera with a half-angle beta between
/// them, and the nearest point of the log is d away, then a round section of
/// radius r satisfies
///
///     sin(beta) = r / (d + r)       so       r = d sin(beta) / (1 - sin(beta))
///
/// which is exact for a round section. For an oval one it is the width across
/// the line of sight, and [LogGirthModel] turns that into a girth using the
/// shape the end face showed.
///
/// Everything is worked in the plane across the log. Looking along the axis,
/// a trunk is its own cross-section and the lines of sight that graze it are
/// tangent lines to that section -- which is what lets a slice seen at an
/// angle, well ahead of or behind the camera, be measured as if the camera
/// were beside it.
class TrunkProfiler {
  const TrunkProfiler._();

  /// Slices along the log. Fine enough to find a waist, coarse enough that
  /// each slice holds a usable number of returns.
  static const double slabMetres = 0.06;

  static const int minPointsPerSlab = 12;

  /// The sleeve points must fall inside, as a multiple of the widest the near
  /// face measured. Leaves room for a log that thickens away from the end,
  /// and keeps the ground and the next log along out of a slice.
  static const double sleeveWidthFactor = 0.8;

  /// How far a slice's points may spread in depth before the fill is treated
  /// as having left the log.
  static const double maxSlabSpreadMetres = 1.2;

  /// Reads every slice of trunk visible in one frame.
  ///
  /// [origin] and [axis] describe the log as currently understood -- the
  /// near face's centre, and the direction it runs away in.
  static List<TrunkWidthSample> sample(
    DepthFrame frame, {
    required Vector3 origin,
    required Vector3 axis,
    required double maxFaceWidthMetres,
  }) {
    final seedX = frame.width ~/ 2;
    final seedY = frame.height ~/ 2;

    final seedDepth = frame.medianDepthAround(seedX, seedY);
    if (seedDepth == null || frame.fx <= 0) return const [];

    // The fill must reach the last pixel on the log or the edge ray is lost.
    // Near a round edge the depth step between neighbouring pixels grows
    // without limit, so a tolerance fixed in metres stops well short of it;
    // one scaled to a pixel at this range stops at the same grazing angle
    // whatever the distance.
    final pixelMetres = seedDepth / frame.fx;
    final step = math.max(0.03, 8 * pixelMetres);

    final region = FaceScanner.growRegion(
      frame,
      seedX,
      seedY,
      seedDepth,
      stepMetres: step,
      spreadMetres: maxSlabSpreadMetres,
    );

    if (region.pixels.length < minPointsPerSlab * 3) return const [];

    final unitAxis = axis.normalized();
    final basis = perpendicularBasis(unitAxis);
    final e1 = basis.u;
    final e2 = basis.v;

    final camera = frame.cameraPosition;
    final cameraX = camera.dot(e1);
    final cameraY = camera.dot(e2);

    final sleeve = maxFaceWidthMetres * sleeveWidthFactor;

    final slabs = <int, List<Vector3>>{};

    for (final index in region.pixels) {
      final x = index % frame.width;
      final y = index ~/ frame.width;

      final depth = frame.depthAt(x, y);
      if (depth == null) continue;

      final point = frame.toWorld(frame.cameraPointAt(x, y, depth));
      final t = (point - origin).dot(unitAxis);

      if (!t.isFinite) continue;

      slabs.putIfAbsent((t / slabMetres).floor(), () => <Vector3>[]).add(point);
    }

    final samples = <TrunkWidthSample>[];

    for (final points in slabs.values) {
      if (points.length < minPointsPerSlab) continue;

      final sample = _measureSlab(
        points,
        camera: camera,
        cameraX: cameraX,
        cameraY: cameraY,
        e1: e1,
        e2: e2,
        axis: unitAxis,
        origin: origin,
        sleeve: sleeve,
        fx: frame.fx,
        maxWidth: maxFaceWidthMetres * 2.5,
      );

      if (sample != null) samples.add(sample);
    }

    return samples;
  }

  static TrunkWidthSample? _measureSlab(
    List<Vector3> points, {
    required Vector3 camera,
    required double cameraX,
    required double cameraY,
    required Vector3 e1,
    required Vector3 e2,
    required Vector3 axis,
    required Vector3 origin,
    required double sleeve,
    required double fx,
    required double maxWidth,
  }) {
    final count = points.length;

    // Into the plane across the log.
    final qx = List<double>.filled(count, 0);
    final qy = List<double>.filled(count, 0);

    for (var i = 0; i < count; i++) {
      qx[i] = points[i].dot(e1);
      qy[i] = points[i].dot(e2);
    }

    // The sleeve is centred on this slice's own points rather than on the
    // axis. A few degrees of error in the axis walks an axis-centred sleeve
    // clean off the log a couple of metres away; a slice's own median does
    // not drift.
    final middleX = _median(qx);
    final middleY = _median(qy);

    final reference = math.atan2(middleY - cameraY, middleX - cameraX);

    var lowest = double.infinity;
    var lowestWidening = 0.0;
    var highest = -double.infinity;
    var highestWidening = 0.0;

    final ranges = <double>[];
    var centre = Vector3.zero();
    var kept = 0;

    for (var i = 0; i < count; i++) {
      if ((qx[i] - middleX).abs() > sleeve) continue;
      if ((qy[i] - middleY).abs() > sleeve) continue;

      final dx = qx[i] - cameraX;
      final dy = qy[i] - cameraY;
      final range = math.sqrt(dx * dx + dy * dy);

      // Standing over the log, or a stray return at the lens.
      if (range < 0.05) continue;

      var angle = math.atan2(dy, dx) - reference;
      while (angle > math.pi) {
        angle -= 2 * math.pi;
      }
      while (angle <= -math.pi) {
        angle += 2 * math.pi;
      }

      // The real edge lies somewhere in the gap between the last pixel on the
      // log and the first one off it -- on average, half a pixel out. A pixel
      // spans 1/fx radians of the image, which in this plane is stretched by
      // however far the slice sits ahead of or behind the camera.
      final fullRange = (points[i] - camera).length;
      final widening = 0.5 * fullRange / (fx * range);

      if (angle < lowest) {
        lowest = angle;
        lowestWidening = widening;
      }
      if (angle > highest) {
        highest = angle;
        highestWidening = widening;
      }

      ranges.add(range);
      centre += points[i];
      kept++;
    }

    if (kept < minPointsPerSlab) return null;

    final halfAngle =
        ((highest + highestWidening) - (lowest - lowestWidening)) / 2;

    if (!halfAngle.isFinite || halfAngle <= 0.004 || halfAngle >= 1.2) {
      return null;
    }

    final sine = math.sin(halfAngle);
    if (sine >= 0.95) return null;

    // Nearest surface, taken at a low percentile rather than the single
    // closest return, so one noisy point in front of the bark cannot pull the
    // log towards the camera.
    ranges.sort();
    final nearest = ranges[(ranges.length * 0.02).floor()];

    final radius = nearest * sine / (1 - sine);
    final width = 2 * radius;

    if (!width.isFinite || width <= 0.02 || width > maxWidth) return null;

    final bisector = reference + (lowest + highest) / 2;
    final towardLog = e1 * math.cos(bisector) + e2 * math.sin(bisector);

    final lateral = axis.cross(towardLog);
    if (lateral.length < 1e-6) return null;
    lateral.normalize();

    centre.scale(1 / kept);

    return TrunkWidthSample(
      axialPosition: (centre - origin).dot(axis),
      widthMetres: width,
      lateral: lateral,
      centre: centre,
    );
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }
}

/// Where along a log its thinnest girth was found.
enum GirthSource { nearEnd, farEnd, trunk }

/// The thinnest girth on a log and where it came from.
class MinimumGirth {
  final double girthMetres;
  final GirthSource source;

  /// Whether the trunk between the ends was seen well enough to look for a
  /// waist. When false, the thinner end stands for the whole log.
  final bool trunkSeen;

  /// Metres from the near end.
  final double axialPosition;

  const MinimumGirth({
    required this.girthMetres,
    required this.source,
    required this.trunkSeen,
    required this.axialPosition,
  });
}

/// A girth measured or inferred at one place along the log.
class GirthAtPosition {
  final double axialPosition;
  final double girthMetres;

  /// False only at the end faces, where the whole outline was seen.
  final bool inferred;

  const GirthAtPosition({
    required this.axialPosition,
    required this.girthMetres,
    required this.inferred,
  });
}

/// Turns end faces and a walk down the trunk into the girths the trade bills
/// on.
///
/// The problem this solves: a girth is a measurement all the way round, and
/// from the side of a log only one way across it can be seen at a time.
/// Walking round each section is not an option -- logs lie on the ground and
/// sit in stacks.
///
/// The way out is Cauchy's formula. For any convex outline the perimeter is
/// exactly pi times the *mean* width taken over all directions. At the cut
/// end the whole outline is in view, so its perimeter and its width in any
/// particular direction are both known, and their ratio is a property of
/// that log's shape:
///
///     girth here = width here across a direction
///                  x (face girth / face width across that same direction)
///
/// For a round log the bracket is simply pi. For an oval one it is pi
/// corrected by however oval the end was, seen from the same side the trunk
/// is being viewed from -- the correction a circle fit cannot make, and the
/// reason an oval log no longer reads as a circle drawn through its narrow
/// way across.
///
/// Where both ends were scanned the ratio is carried from one to the other,
/// so a log that is oval at one end and rounder at the other is followed
/// rather than averaged.
class LogGirthModel {
  final FaceScan nearFace;
  final FaceScan? farFace;

  /// Straight-line distance between the centres of the two end faces -- the
  /// length a tape stretched between the ends reads.
  final double lengthMetres;

  final List<TrunkWidthSample> samples;

  /// True when the far end was marked rather than scanned, so its girth was
  /// never seen.
  final bool farEndEstimated;

  const LogGirthModel({
    required this.nearFace,
    required this.farFace,
    required this.lengthMetres,
    required this.samples,
    this.farEndEstimated = false,
  });

  /// Slices the girth profile is reported at. Coarser than the sampler's
  /// own, so that several passes of the camera over the same stretch have to
  /// agree before a thin spot is believed.
  static const double reportingSlabMetres = 0.12;

  /// A slice must be read at least this often before it counts. One reading
  /// at one instant, at one grazing angle, is exactly the evidence that
  /// produces a confident under-measurement.
  static const int minReadingsForSlab = 2;

  /// Fewer measured slices than this and the trunk tells us nothing the ends
  /// did not.
  static const int minTrunkSlabs = 3;

  /// How far below the thinner scanned end the trunk must read before it is
  /// believed to have a waist.
  ///
  /// The end faces are measured all the way round; the trunk is inferred from
  /// one side. Taking the minimum of a series always finds its noise as well
  /// as its signal, so without a margin the trunk would undercut an exactly
  /// measured end on every log, by exactly its own noise -- a small, steady
  /// under-billing of every seller.
  static const double waistMargin = 0.03;

  /// A smaller margin when the far end was never scanned. Then the trunk is
  /// the only evidence of how the log tapers away from the near end, and
  /// holding it to the full margin would ignore a real taper.
  static const double unscannedEndMargin = 0.015;

  double get faceGirthMetres => nearFace.girthMetres;

  double? get farFaceGirthMetres =>
      farEndEstimated ? null : farFace?.girthMetres;

  /// The multiplier that turns a width measured across [lateral] into a
  /// girth, taken from one end face.
  double _ratioFor(FaceScan face, Vector3 lateral) {
    final width = face.outline.widthAcross(lateral);
    if (width == null || width <= 0.01) return math.pi;

    final ratio = face.girthMetres / width;

    // No real log end has a girth less than pi times a width across it, nor
    // much more than a third again. Outside that the outline was bad, and pi
    // -- the round-log answer -- is the safer one.
    return ratio.isFinite ? ratio.clamp(2.9, 4.2).toDouble() : math.pi;
  }

  /// The ratio at a point along the log, carried from one end towards the
  /// other where both were seen.
  double _blendedRatio(Vector3 lateral, double axialPosition) {
    final near = _ratioFor(nearFace, lateral);

    final far = farFace;
    if (far == null || farEndEstimated || lengthMetres <= 0) return near;

    final t = (axialPosition / lengthMetres).clamp(0.0, 1.0);
    return near + (_ratioFor(far, lateral) - near) * t;
  }

  /// Girths inferred along the trunk, one per reporting slice, near end
  /// first.
  List<GirthAtPosition> get trunkProfile {
    final bySlab = <int, List<double>>{};

    for (final sample in samples) {
      final t = sample.axialPosition;

      // The stretch right at each end is skipped: a slice straddling a cut
      // face measures that face's silhouette, which is already known exactly.
      if (t < 0.10) continue;
      if (lengthMetres > 0 && t > lengthMetres - 0.10) continue;

      final girth = sample.widthMetres * _blendedRatio(sample.lateral, t);
      if (!girth.isFinite || girth <= 0) continue;

      bySlab
          .putIfAbsent((t / reportingSlabMetres).floor(), () => <double>[])
          .add(girth);
    }

    final result = <GirthAtPosition>[];

    for (final entry in bySlab.entries) {
      final readings = entry.value;
      if (readings.length < minReadingsForSlab) continue;

      readings.sort();

      result.add(
        GirthAtPosition(
          axialPosition: (entry.key + 0.5) * reportingSlabMetres,
          girthMetres: readings[readings.length ~/ 2],
          inferred: true,
        ),
      );
    }

    result.sort((a, b) => a.axialPosition.compareTo(b.axialPosition));
    return result;
  }

  /// Every girth the scan can speak to, end faces included, near end first.
  List<GirthAtPosition> get profile {
    final result = <GirthAtPosition>[
      GirthAtPosition(
        axialPosition: 0,
        girthMetres: nearFace.girthMetres,
        inferred: false,
      ),
      ...trunkProfile,
    ];

    final far = farFaceGirthMetres;
    if (far != null) {
      result.add(
        GirthAtPosition(
          axialPosition: lengthMetres,
          girthMetres: far,
          inferred: false,
        ),
      );
    }

    return result;
  }

  /// The thinnest girth on the log -- the figure the trade bills on.
  ///
  /// The end faces are the baseline, because they are measured all the way
  /// round. The trunk can only lower the answer, and only when a thin spot
  /// is corroborated by the slices either side of it and falls clearly below
  /// the thinner end; otherwise the thinner end stands for the log.
  MinimumGirth get minimumGirth {
    var best = nearFace.girthMetres;
    var source = GirthSource.nearEnd;
    var position = 0.0;

    final far = farFaceGirthMetres;
    if (far != null && far < best) {
      best = far;
      source = GirthSource.farEnd;
      position = lengthMetres;
    }

    final trunk = trunkProfile;

    if (trunk.length < minTrunkSlabs) {
      return MinimumGirth(
        girthMetres: best,
        source: source,
        trunkSeen: false,
        axialPosition: position,
      );
    }

    final smoothed = _medianSmoothed(
      trunk.map((p) => p.girthMetres).toList(growable: false),
    );

    var thinnest = 0;
    for (var i = 1; i < smoothed.length; i++) {
      if (smoothed[i] < smoothed[thinnest]) thinnest = i;
    }

    final margin = far == null ? unscannedEndMargin : waistMargin;

    if (smoothed[thinnest] < best * (1 - margin)) {
      return MinimumGirth(
        girthMetres: smoothed[thinnest],
        source: GirthSource.trunk,
        trunkSeen: true,
        axialPosition: trunk[thinnest].axialPosition,
      );
    }

    return MinimumGirth(
      girthMetres: best,
      source: source,
      trunkSeen: true,
      axialPosition: position,
    );
  }

  /// A three-wide median along the series.
  ///
  /// A minimum over raw readings is a minimum over the noise as much as over
  /// the log. Smoothing first means a thin spot has to show up in the slices
  /// on either side of it too before it can set the price.
  static List<double> _medianSmoothed(List<double> values) {
    if (values.length < 3) return List<double>.from(values);

    final out = <double>[];

    for (var i = 0; i < values.length; i++) {
      final window = <double>[
        values[math.max(0, i - 1)],
        values[i],
        values[math.min(values.length - 1, i + 1)],
      ]..sort();

      out.add(window[1]);
    }

    return out;
  }
}
