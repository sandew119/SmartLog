import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../models/log_face_outline.dart';
import '../utils/ellipse_fit.dart';

/// The result of tracing a log face, with enough information for the UI to
/// decide whether to trust it.
class LogFaceDetection {
  final LogFaceOutline outline;

  /// The shape the rays were fitted to. A round face photographed at an
  /// angle is an ellipse, so this is the model, and [outline] is that model
  /// allowed to bend slightly where the log genuinely is not round.
  final Ellipse ellipse;

  /// Fraction of rays whose edge agreed with the fitted shape, 0..1.
  ///
  /// This is a stronger signal than the old "did the ray find *an* edge":
  /// a ray can find a crisp edge on a shadow or a background object and be
  /// completely wrong. Agreement with the overall shape catches that.
  final double confidence;

  final int rayCount;

  /// Rays discarded either for finding no edge or for disagreeing with the
  /// fitted shape.
  final int weakRays;

  const LogFaceDetection({
    required this.outline,
    required this.ellipse,
    required this.confidence,
    required this.rayCount,
    required this.weakRays,
  });

  /// Below this the UI should say so and invite the user to adjust rather
  /// than quietly packing boards against a guess.
  bool get isReliable => confidence >= 0.6;
}

/// Finds the boundary of a log's cut face from a point the user tapped.
///
/// The previous version assumed the face was *brighter* than everything
/// around it and looked for the biggest luminance step along each ray. That
/// works on fresh pale timber against dark ground and fails on everything
/// else -- a face in shade, a log on pale sawdust, weathered grey ends,
/// direct sun blowing out the background. Three changes fix it:
///
/// 1. **No brightness assumption.** A colour model is sampled from where the
///    user actually tapped, and an edge is where the image stops looking
///    like *that*. Dark face on light ground works exactly as well as the
///    reverse.
/// 2. **Two cues, not one.** Colour change says where the face ends; the
///    gradient says there is a real boundary there rather than a gradual
///    shading drift. Both must agree.
/// 3. **A shape model.** Rays are fitted to an ellipse, which is what a
///    round face photographed at an angle actually is. One ray landing on a
///    shadow or a branch stub no longer puts a spike in the outline; it
///    gets outvoted.
class LogFaceDetector {
  /// Detection runs on a downscaled copy: much faster, it smooths sensor
  /// noise for free, and it keeps the tuning constants below meaning the
  /// same thing regardless of the phone's megapixel count.
  static const int _workingSize = 512;

  /// Half-width of the window either side of a candidate edge, in working
  /// pixels. Wide enough to ignore grain, narrow enough to sit on the bark.
  static const int _edgeWindow = 4;

  /// Ignore the first few pixels: a fingertip is imprecise, and the pith at
  /// the centre of a log is often dark enough to look like an edge.
  static const int _minRadius = 10;

  /// How far the colour must shift, in robust standard deviations of the
  /// sampled face, before it counts as leaving the face.
  static const double _minColourStep = 1.2;

  /// Minimum RGB distance across a candidate before it counts as a boundary
  /// at all, on a 0..255 scale.
  ///
  /// Low enough for a weathered grey log against pale ground, high enough
  /// that sensor noise and the shading across a curved surface do not
  /// register as edges.
  static const double _minEdgeContrast = 26;

  /// How far past the first boundary the search will still accept an edge,
  /// as a multiple of that first radius.
  ///
  /// Bark is a skin, not a second log: on any log worth sawing it is a small
  /// fraction of the radius, so half as much again is generous. The cap is
  /// what stops the outward preference walking off the log and onto the
  /// grass behind it.
  static const double _maxBarkExtension = 1.5;

  /// A ray whose edge sits within this fraction of the fitted radius counts
  /// as agreeing with the shape.
  static const double _agreementTolerance = 0.18;

  /// How far the final outline may depart from the fitted ellipse.
  ///
  /// Real logs are out of round and that shape is worth keeping -- it is
  /// yield the circle model used to discard. But unbounded freedom lets one
  /// bad ray put a spike in the boundary, so departure is capped.
  static const double _maxRadialDeviation = 0.22;

  static LogFaceDetection? detect({
    required img.Image image,
    required Offset centre,
    int rayCount = 72,
  }) {
    if (rayCount < 8) return null;
    if (image.width < 16 || image.height < 16) return null;

    // --- working copy -----------------------------------------------------
    final longest = math.max(image.width, image.height);
    final scale = longest > _workingSize ? _workingSize / longest : 1.0;

    final work = scale < 1.0
        ? img.copyResize(
            image,
            width: (image.width * scale).round(),
            height: (image.height * scale).round(),
          )
        : image;

    final seed = Offset(centre.dx * scale, centre.dy * scale);

    if (seed.dx < 0 ||
        seed.dy < 0 ||
        seed.dx >= work.width ||
        seed.dy >= work.height) {
      return null;
    }

    // Blur before differencing so bark texture and sensor noise do not read
    // as edges; the real boundary survives a couple of pixels of blur.
    final blurred = img.gaussianBlur(work.clone(), radius: 2);
    final gradient = img.sobel(img.grayscale(blurred.clone()));

    final face = _FaceColour.sample(blurred, seed);
    if (face == null) return null;

    // --- cast rays --------------------------------------------------------
    final maxRadius = _maxUsableRadius(work, seed);
    if (maxRadius <= _minRadius + _edgeWindow * 2) return null;

    final hits = <Offset>[];
    final radii = List<double?>.filled(rayCount, null);

    for (var i = 0; i < rayCount; i++) {
      final angle = 2 * math.pi * i / rayCount;

      final r = _findEdgeAlongRay(
        colour: blurred,
        gradient: gradient,
        face: face,
        origin: seed,
        angle: angle,
        maxRadius: maxRadius,
      );

      if (r == null) continue;

      radii[i] = r;
      hits.add(
        Offset(seed.dx + r * math.cos(angle), seed.dy + r * math.sin(angle)),
      );
    }

    if (hits.length < 8) return null;

    // --- fit a shape to them ---------------------------------------------
    final ellipse = fitEllipseIrls(hits);
    if (ellipse == null) return null;

    // --- refine, bounded --------------------------------------------------
    // Re-measure from the fitted centre rather than the tap: the tap is
    // wherever the user's thumb landed, which on an oval face can be well
    // off-centre and skews every radius.
    final refined = <double>[];
    var agreed = 0;

    for (var i = 0; i < rayCount; i++) {
      final angle = 2 * math.pi * i / rayCount;
      final expected = ellipse.radiusAt(angle);

      final measured = _findEdgeAlongRay(
        colour: blurred,
        gradient: gradient,
        face: face,
        origin: ellipse.centre,
        angle: angle,
        maxRadius: _maxUsableRadius(work, ellipse.centre),
      );

      if (measured == null || expected <= 0) {
        refined.add(expected);
        continue;
      }

      final deviation = (measured - expected) / expected;

      if (deviation.abs() <= _agreementTolerance) agreed++;

      final clamped = deviation.clamp(
        -_maxRadialDeviation,
        _maxRadialDeviation,
      );

      refined.add(expected * (1 + clamped));
    }

    final smoothed = _smoothRing(refined);

    // Back to the original image's pixels.
    final inverse = 1 / scale;

    final outline = LogFaceOutline.fromRadii(
      Offset(ellipse.centre.dx * inverse, ellipse.centre.dy * inverse),
      [for (final r in smoothed) r * inverse],
    );

    return LogFaceDetection(
      outline: outline,
      ellipse: Ellipse(
        centre: Offset(
          ellipse.centre.dx * inverse,
          ellipse.centre.dy * inverse,
        ),
        semiMajor: ellipse.semiMajor * inverse,
        semiMinor: ellipse.semiMinor * inverse,
        rotation: ellipse.rotation,
      ),
      confidence: agreed / rayCount,
      rayCount: rayCount,
      weakRays: rayCount - agreed,
    );
  }

  /// How far two colours differ once brightness is divided out.
  ///
  /// Each colour is reduced to its share of red, green and blue in its own
  /// total, so scaling every channel by the same factor -- which is what
  /// shade does -- leaves the value unchanged. What survives is a change of
  /// material.
  static double _chromaticShift(
    double innerR,
    double innerG,
    double innerB,
    double outerR,
    double outerG,
    double outerB,
  ) {
    final innerTotal = innerR + innerG + innerB;
    final outerTotal = outerR + outerG + outerB;

    // Near-black on either side carries no reliable hue: the ratios are
    // then decided by sensor noise, and a large meaningless shift would
    // make deep shadow look like the strongest boundary on the ray.
    if (innerTotal < 24 || outerTotal < 24) return 0;

    final dr = innerR / innerTotal - outerR / outerTotal;
    final dg = innerG / innerTotal - outerG / outerTotal;
    final db = innerB / innerTotal - outerB / outerTotal;

    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  /// Distance from [origin] to the nearest image edge, so rays never sample
  /// outside the picture.
  static double _maxUsableRadius(img.Image image, Offset origin) {
    return [
      origin.dx,
      origin.dy,
      image.width - 1 - origin.dx,
      image.height - 1 - origin.dy,
    ].reduce(math.min);
  }

  /// Walks one ray and returns the radius where the face ends.
  ///
  /// Scores every candidate on how much the colour stops matching the face
  /// *across* it, weighted by whether there is a genuine gradient there.
  /// Taking the best-scoring radius rather than the first over a threshold
  /// matters: bark often gives a weak early edge before the true boundary.
  static double? _findEdgeAlongRay({
    required img.Image colour,
    required img.Image gradient,
    required _FaceColour face,
    required Offset origin,
    required double angle,
    required double maxRadius,
  }) {
    final limit = maxRadius.floor();
    if (limit <= _minRadius + _edgeWindow) return null;

    final dx = math.cos(angle);
    final dy = math.sin(angle);

    // Colour along the ray, and how far it is from the face model.
    //
    // Both are needed. The distance says whether we are still on the sawn
    // face; the colour itself is what detects a boundary, and it has to be
    // the colour rather than the distance because a transition can move
    // *back towards* the face colour. Bark is further from pale sawn timber
    // than the ground behind it is, so bark-to-ground is a fall in distance
    // and a rise-only test never sees the outer edge at all.
    final reds = List<double>.filled(limit + 1, 0);
    final greens = List<double>.filled(limit + 1, 0);
    final blues = List<double>.filled(limit + 1, 0);
    final distances = List<double>.filled(limit + 1, 0);

    for (var r = 0; r <= limit; r++) {
      final x = (origin.dx + dx * r).round();
      final y = (origin.dy + dy * r).round();

      if (x < 0 || y < 0 || x >= colour.width || y >= colour.height) {
        final previous = r > 0 ? r - 1 : 0;
        reds[r] = reds[previous];
        greens[r] = greens[previous];
        blues[r] = blues[previous];
        distances[r] = distances[previous];
        continue;
      }

      final p = colour.getPixel(x, y);

      reds[r] = p.r.toDouble();
      greens[r] = p.g.toDouble();
      blues[r] = p.b.toDouble();
      distances[r] = face.distance(p);
    }

    final candidates = <({double radius, double score})>[];

    for (var r = _minRadius; r <= limit - _edgeWindow; r++) {
      var innerR = 0.0, innerG = 0.0, innerB = 0.0;
      var outerR = 0.0, outerG = 0.0, outerB = 0.0;
      var outerDistance = 0.0;

      for (var k = 1; k <= _edgeWindow; k++) {
        final before = math.max(0, r - k);
        final after = math.min(limit, r + k);

        innerR += reds[before];
        innerG += greens[before];
        innerB += blues[before];

        outerR += reds[after];
        outerG += greens[after];
        outerB += blues[after];
        outerDistance += distances[after];
      }

      innerR /= _edgeWindow;
      innerG /= _edgeWindow;
      innerB /= _edgeWindow;
      outerR /= _edgeWindow;
      outerG /= _edgeWindow;
      outerB /= _edgeWindow;
      outerDistance /= _edgeWindow;

      // Whatever is beyond this radius has to already be something other
      // than the sawn face. That is what keeps growth rings, saw marks and
      // the pith -- all real colour boundaries, all inside the timber --
      // from being mistaken for where the log ends.
      if (outerDistance < _minColourStep) continue;

      final change = math.sqrt(
        math.pow(outerR - innerR, 2) +
            math.pow(outerG - innerG, 2) +
            math.pow(outerB - innerB, 2),
      );

      if (change < _minEdgeContrast) continue;

      final gx = (origin.dx + dx * r).round().clamp(0, gradient.width - 1);
      final gy = (origin.dy + dy * r).round().clamp(0, gradient.height - 1);

      final edgeStrength = gradient.getPixel(gx, gy).luminanceNormalized;

      // How much the *colour* changes, as opposed to the brightness.
      //
      // This is what separates a shadow from a material boundary, and it is
      // the difference the detector was missing. Shade scales all three
      // channels together: the timber under it is still timber-coloured,
      // just darker. A real edge -- sawn face to bark, bark to ground -- is
      // a change of material, and materials differ in hue as well as in
      // brightness.
      //
      // Without this, the hard line where a shadow crosses a log is the
      // strongest boundary on the ray, the search anchors on it, and the
      // face is reported as ending there. Measured on a half-shaded face:
      // a radius of 90 against a true 110, and no warning, because the
      // shadow edge is genuinely crisp and the fit through it genuinely
      // consistent.
      final chromatic = _chromaticShift(
        innerR, innerG, innerB, //
        outerR, outerG, outerB,
      );

      // A weight, not a gate. A grey log on grey concrete is a real edge
      // with almost no hue change, and refusing it outright would trade one
      // failure for another; weighting merely means a shadow has to be a
      // far bigger step than a material boundary to outrank it.
      final chromaWeight = (0.35 + chromatic * 8).clamp(0.35, 2.0);

      // The gradient corroborates rather than decides. A soft but real
      // colour boundary still counts; a hard gradient with no colour change
      // (a shadow line across the face) does not.
      candidates.add(
        (
          radius: r.toDouble(),
          score: change * (0.4 + edgeStrength) * chromaWeight,
        ),
      );
    }

    if (candidates.isEmpty) return null;

    // The outermost credible edge, not the strongest one.
    //
    // A sawn end goes heartwood, sapwood, bark, background. The strongest
    // boundary is nearly always sapwood-to-bark, because bark looks nothing
    // like a sawn face and the luminance step is large -- so picking the
    // best-scoring candidate stops the outline at the *inner* edge of the
    // bark and reports a log narrower than it is. Bark is part of the log.
    //
    // Bounded by distance rather than by score. Score is the wrong yardstick
    // on its own: the gradient term makes the sapwood-to-bark step several
    // times the bark-to-ground one, so any threshold loose enough to admit
    // the outer edge is also loose enough to admit grass.
    //
    // The cap is anchored on the *strongest* boundary rather than the first
    // one. The first can be an interior feature -- the hard line where a
    // shadow falls across the face is a genuine colour boundary and often
    // comes first -- and anchoring there would trap the outline inside the
    // shadow. The strongest is reliably the log's own edge, so the search
    // extends outward from there and picks up bark without being able to
    // reach the scenery.
    var strongest = candidates.first;

    for (final candidate in candidates) {
      if (candidate.score > strongest.score) strongest = candidate;
    }

    final reach = strongest.radius * _maxBarkExtension;

    var chosen = strongest;

    for (final candidate in candidates) {
      if (candidate.radius > strongest.radius && candidate.radius <= reach) {
        chosen = candidate;
      }
    }

    return chosen.radius;
  }

  /// Circular 3-tap smoothing, so a single ray cannot leave a tooth in the
  /// outline that the packing engine would then have to route around.
  static List<double> _smoothRing(List<double> radii) {
    if (radii.length < 3) return radii;

    return List.generate(radii.length, (i) {
      final prev = radii[(i - 1 + radii.length) % radii.length];
      final next = radii[(i + 1) % radii.length];

      return (prev + radii[i] * 2 + next) / 4;
    });
  }
}

/// What the face looks like, sampled from where the user tapped.
///
/// Held as a median and a robust spread per channel. The median resists the
/// user's thumb catching a knot or a saw mark, and the spread is what makes
/// the threshold adaptive: a clean sawn end is uniform and any change is
/// significant, while a rough weathered end varies a lot on its own and
/// needs a bigger change before it means anything.
class _FaceColour {
  final double medianR;
  final double medianG;
  final double medianB;

  final double spreadR;
  final double spreadG;
  final double spreadB;

  const _FaceColour({
    required this.medianR,
    required this.medianG,
    required this.medianB,
    required this.spreadR,
    required this.spreadG,
    required this.spreadB,
  });

  static _FaceColour? sample(img.Image image, Offset centre) {
    final radius =
        math.max(4, (math.max(image.width, image.height) * 0.03).round());

    final rs = <double>[];
    final gs = <double>[];
    final bs = <double>[];

    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy > radius * radius) continue;

        final x = (centre.dx + dx).round();
        final y = (centre.dy + dy).round();

        if (x < 0 || y < 0 || x >= image.width || y >= image.height) continue;

        final p = image.getPixel(x, y);
        rs.add(p.r.toDouble());
        gs.add(p.g.toDouble());
        bs.add(p.b.toDouble());
      }
    }

    if (rs.length < 9) return null;

    return _FaceColour(
      medianR: _median(rs),
      medianG: _median(gs),
      medianB: _median(bs),
      spreadR: _spread(rs),
      spreadG: _spread(gs),
      spreadB: _spread(bs),
    );
  }

  /// Distance in robust standard deviations. Scale-free, so one threshold
  /// works for a uniform sawn end and a mottled weathered one alike.
  double distance(img.Pixel p) {
    final dr = (p.r.toDouble() - medianR) / spreadR;
    final dg = (p.g.toDouble() - medianG) / spreadG;
    final db = (p.b.toDouble() - medianB) / spreadB;

    return math.sqrt(dr * dr + dg * dg + db * db) / math.sqrt(3);
  }

  static double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    return sorted[sorted.length ~/ 2];
  }

  static double _spread(List<double> values) {
    final median = _median(values);
    final deviations = [for (final v in values) (v - median).abs()];

    final mad = _median(deviations) * 1.4826;

    // Floor the spread so a perfectly flat patch does not make every
    // neighbouring pixel look infinitely far away.
    return math.max(mad, 6);
  }
}
