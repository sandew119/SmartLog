import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../models/log_measurement.dart';
import 'depth_frame.dart';
import 'face_scan.dart';
import 'log_girth_model.dart';
import 'log_volume_pipeline.dart';
import 'scan_diagnostics.dart';

/// The steps of a scan, in the order the user does them.
///
/// 1. Point at one cut end. The app finds it, traces round it, and says so.
/// 2. Walk to the other end. The app reads the trunk on the way.
/// 3. Point at the other cut end. The app finds it, and the length is the
///    straight line between the two.
enum ScanStep { nearEnd, walk, farEnd, finished }

/// Moments the screen should mark with a sound or a buzz.
enum ScanEvent { nearEndLocked, farEndFound, finished }

enum GuidanceTone { neutral, good, warning }

/// Whether a face the scanner can see is the other end of the log whose first
/// end it already has -- and if not, the honest reason.
///
/// There used to be one reason: "that is the end you already scanned",
/// whatever had actually gone wrong. A face at the wrong angle, a face too
/// close to the first, and a face metres off to one side all got that
/// sentence, which is wrong for two of the three and gives the user nothing
/// to act on.
enum FarEndVerdict {
  accepted,

  /// The first end again, or so near it that it might as well be.
  sameEnd,

  /// Faces the way the first end does, so it cannot be the far end of the
  /// same log.
  facingTheSameWay,

  /// Faces the right way but is less than a hand's breadth along.
  tooClose,

  /// Faces the right way and is far enough along, but is well to one side of
  /// the line the log runs on -- another log's end.
  offTheLine,
}

/// A far-end verdict with the numbers behind it, which the diagnostics report
/// carries so a wrong call can be traced to the measurement that caused it.
class FarEndCheck {
  final FarEndVerdict verdict;

  /// Distance of the face's centre from the first end's centre.
  final double separationMetres;

  /// How far along the log's axis, and how far off it, the face sits.
  final double alongMetres;
  final double sidewaysMetres;

  /// Dot product of the two faces' normals: -1 is exactly opposite, +1 is
  /// facing the same way.
  final double facing;

  /// How far off the axis this face may sit and still be accepted.
  final double allowedSidewaysMetres;

  const FarEndCheck({
    required this.verdict,
    required this.separationMetres,
    required this.alongMetres,
    required this.sidewaysMetres,
    required this.facing,
    required this.allowedSidewaysMetres,
  });

  @override
  String toString() => '${verdict.name}: '
      'separation ${separationMetres.toStringAsFixed(2)} m, '
      'along ${alongMetres.toStringAsFixed(2)} m, '
      'sideways ${sidewaysMetres.toStringAsFixed(2)} m '
      '(allowed ${allowedSidewaysMetres.toStringAsFixed(2)}), '
      'facing ${facing.toStringAsFixed(2)}';
}

/// One instruction for the user, and nothing else.
///
/// Short on purpose. The people using this are standing in a timber yard with
/// a phone in one hand; a sentence they have to read twice is a sentence
/// they will not read.
class ScanGuidance {
  final String headline;
  final String? detail;
  final GuidanceTone tone;

  /// How far through the current step, 0..1, or null when the step has no
  /// natural progress to show.
  final double? progress;

  const ScanGuidance(
    this.headline, {
    this.detail,
    this.tone = GuidanceTone.neutral,
    this.progress,
  });
}

/// A finished scan.
class LogScanResult {
  final FaceScan nearFace;
  final FaceScan? farFace;

  /// Straight line between the centres of the two ends.
  final double lengthMetres;

  /// True when the far end was marked by eye rather than scanned.
  final bool lengthEstimated;

  final MinimumGirth minimumGirth;

  final List<GirthAtPosition> profile;

  final int trunkReadings;

  const LogScanResult({
    required this.nearFace,
    required this.farFace,
    required this.lengthMetres,
    required this.lengthEstimated,
    required this.minimumGirth,
    required this.profile,
    required this.trunkReadings,
  });

  double get faceGirthMetres => nearFace.girthMetres;

  double? get farFaceGirthMetres => farFace?.girthMetres;

  /// In the form the rest of the app stores, prices and prints.
  LogMeasurement toMeasurement() {
    final minGirthInches =
        MeasurementUnits.metresToInches(minimumGirth.girthMetres);

    final far = farFace;

    return LogMeasurement(
      // The round-log diameter with the same girth. Stored because every
      // saved log has always carried one; girth is the figure billed on.
      minDiameterInches: minGirthInches / math.pi,
      lengthFeet: MeasurementUnits.metresToFeet(lengthMetres),
      source: MeasurementSourceKind.lidar,
      tracedGirthInches: minGirthInches,
      diameterProfileInches: [
        for (final p in profile)
          MeasurementUnits.metresToInches(p.girthMetres) / math.pi,
      ],
      meanResidualMm: nearFace.flatnessMm,
      faceGirthInches: MeasurementUnits.metresToInches(faceGirthMetres),
      farFaceGirthInches:
          far == null ? null : MeasurementUnits.metresToInches(far.girthMetres),
      minGirthSource: minimumGirth.source,
      trunkMeasured: minimumGirth.trunkSeen,
      lengthEstimated: lengthEstimated,
    );
  }
}

class _Candidate {
  final FaceScan face;
  final double time;

  const _Candidate(this.face, this.time);
}

/// Everything a scan knows, and every decision about what happens next.
///
/// Kept apart from the screen and from the native camera so the whole flow
/// -- lock-on, walk, far end, fallbacks -- can be driven frame by frame in a
/// test, with no phone. That is the only way to be sure a scan *can* finish
/// before handing it to someone in a yard. The previous scanner could not:
/// it required the user to walk all the way round a log lying on the ground,
/// which no one can do, and there was no test that would have said so.
///
/// The rules it follows:
///
/// - **Nothing to tap.** The user points; the middle of the screen is the
///   answer. A tap on a log end resolved through ARKit's plane estimate,
///   which a log end does not have, is what stopped the last scanner ever
///   starting.
/// - **Locks on its own.** A face is accepted once several frames agree on
///   it. The user is told it is done; they are never asked to judge.
/// - **Strict first, then patient.** Square-on is asked for, because it is
///   more accurate. If the user cannot get square-on, a steady reading is
///   accepted anyway after a few seconds. A scan that never finishes is
///   worth less than one that is 1% less accurate.
/// - **Always a way out.** If the far end cannot be scanned -- buried in a
///   stack, split, rotten -- it can be marked by eye, and the result says the
///   length was estimated.
class LogScanSession {
  LogScanSession();

  /// Readings that must agree before a face is accepted.
  ///
  /// Three, not four in a row. Frame to frame the traced girth of a face
  /// moves by a fraction of a percent on a real-looking sensor -- see
  /// `face_yard_test.dart` -- so agreement is quick to reach when the aim is
  /// steady; what the count guards against is a single odd frame. What it
  /// must not do is demand *consecutive* good frames: one dropped frame
  /// among four used to start the count again, and that, with a face that
  /// was only found on some frames, is where the waiting came from.
  static const int lockReadings = 3;

  /// How recent those readings must be, in seconds.
  static const double lockWindowSeconds = 2.0;

  /// How closely their girths must agree with the middle one, as a fraction.
  static const double lockGirthAgreement = 0.04;

  /// How far apart their centres may be.
  static const double lockCentreAgreementMetres = 0.03;

  /// Square enough to lock at once. The detector accepts up to 62 degrees and
  /// measures within a few percent all the way there; a vertical end seen from
  /// a phone held at chest height, a metre away, is already at 50. The old
  /// limit of 35 meant every ordinary stance was "not square", and each lock
  /// waited out the patience below.
  static const double squareTiltDegrees = 55;

  /// After this long holding a steady face that is not quite square, take it.
  static const double patienceSeconds = 1.5;

  /// The nearest a face may be to the first end and still count as another
  /// place: anything closer is taken to be the first end again.
  static const double sameEndMetres = 0.20;

  /// How far from opposite the two ends' normals may be. Two angled chainsaw
  /// cuts can put them 40 degrees off, so this is generous: -0.45 is 63
  /// degrees off opposite.
  static const double oppositeFacingLimit = -0.45;

  /// The shortest piece the scan will report.
  static const double minLengthMetres = 0.15;

  /// Trunk readings kept. A long walk at ten frames a second would otherwise
  /// grow without bound; this is a few minutes of walking.
  static const int maxTrunkSamples = 8000;

  /// How far a far-end candidate may sit off the near end's axis, as a fixed
  /// allowance plus a share of the distance along. Generous, because a
  /// chainsaw rarely cuts exactly square: a 10 degree cut tilts the axis the
  /// near face implies by 10 degrees, which is half a metre over three.
  static const double farEndOffsetAllowanceMetres = 0.30;
  static const double farEndOffsetPerMetre = 0.36;

  ScanStep _step = ScanStep.nearEnd;

  FaceScan? _nearFace;
  FaceScan? _farFace;

  bool _lengthEstimated = false;
  double? _estimatedLength;

  final List<_Candidate> _candidates = [];
  double? _steadySince;

  /// How many of the recent readings agree, for the progress ring.
  int _agreeing = 0;

  final List<TrunkWidthSample> _samples = [];

  FaceAttempt? _lastAttempt;

  /// What the last far-end candidate was judged to be, or null when no face
  /// was in view.
  FarEndCheck? _farCheck;
  FarEndVerdict? _loggedVerdict;

  /// Everything the scan did, for the report the user can copy out.
  final ScanDiagnostics diagnostics = ScanDiagnostics();

  /// The most recent frame, kept only so a tap can be resolved against it.
  DepthFrame? _lastFrame;

  /// Where the user asked the scanner to look, as a point in the world so it
  /// stays on the log end however the phone moves. Null means the middle of
  /// the screen.
  Vector3? _aimWorld;
  bool _aimOnScreen = true;

  /// The user vouched for the far end although the geometry doubted it.
  bool _farEndVouched = false;

  bool _tracking = true;
  String _trackingReason = '';
  bool _sawAnyFrame = false;

  double? _along;
  double _furthestAlongOnLog = 0;
  bool _offTheLog = false;

  double _now = 0;

  ScanStep get step => _step;

  FaceScan? get nearFace => _nearFace;
  FaceScan? get farFace => _farFace;

  /// The face the scanner is looking at right now, if any -- for the live
  /// girth on screen and for the "Use this" button.
  FaceScan? get currentFace {
    if (_step != ScanStep.nearEnd && _step != ScanStep.farEnd) return null;

    final face = _lastAttempt?.face;
    if (face == null) return null;

    // The first end seen again is not something to offer as the far one.
    if (_step == ScanStep.farEnd &&
        _farCheck?.verdict == FarEndVerdict.sameEnd) {
      return null;
    }

    return face;
  }

  /// How far along the log the middle of the screen is, in metres from the
  /// near end.
  double? get alongMetres => _along;

  /// The furthest point along the log the user has aimed at.
  double get furthestAlongMetres => _furthestAlongOnLog;

  int get trunkReadings => _samples.length;

  bool get trackingReliable => _tracking;

  /// How far the current lock has got, 0..1. Fills as readings agree.
  double get lockProgress =>
      (_agreeing / lockReadings).clamp(0.0, 1.0).toDouble();

  /// The trunk widths read so far, converted to a girth at each place along
  /// the log, for drawing while the user walks. Built the same way the result
  /// is, from the near end alone, so it is a fair preview of the final
  /// profile and not a different calculation.
  List<GirthAtPosition> get liveProfile {
    final near = _nearFace;
    final axis = _axis;
    if (near == null || axis == null || _samples.isEmpty) return const [];

    final model = LogGirthModel(
      nearFace: near,
      farFace: null,
      lengthMetres: _furthestAlongOnLog,
      samples: [
        for (final s in _samples)
          s.restatedAgainst(origin: near.centre, axis: axis),
      ],
      farEndEstimated: true,
    );

    return model.trunkProfile;
  }

  /// The thinnest girth the walk has found so far, or null before there is any
  /// trunk to speak of. What the live readout shows while the user walks; the
  /// final figure adds the far end.
  MinimumGirth? get liveMinimumGirth {
    final near = _nearFace;
    final axis = _axis;
    if (near == null || axis == null || _samples.length < 8) return null;

    return LogGirthModel(
      nearFace: near,
      farFace: null,
      lengthMetres: _furthestAlongOnLog,
      samples: [
        for (final s in _samples)
          s.restatedAgainst(origin: near.centre, axis: axis),
      ],
      farEndEstimated: true,
    ).minimumGirth;
  }

  /// The verdict on the face in view at the far end, with its numbers.
  FarEndCheck? get farEndCheck => _farCheck;

  /// Whether the user has pointed the scanner somewhere other than the middle
  /// of the screen.
  bool get hasAim => _aimWorld != null;

  /// False when the aimed-at point has moved off the screen, so the scan is
  /// looking at the middle of the screen instead.
  bool get aimVisible => _aimOnScreen;

  /// The point in the world the user aimed at, if any.
  Vector3? get aimPoint => _aimWorld;

  /// The direction the log runs away from the near end.
  Vector3? get _axis {
    final near = _nearFace;
    if (near == null) return null;
    return (-near.normal).normalized();
  }

  // --- Feeding frames -----------------------------------------------------

  /// Processes one frame and returns an event if a step just completed.
  ScanEvent? onFrame(DepthFrame frame) {
    _now = frame.timestamp > 0 ? frame.timestamp : _now + 0.1;
    _sawAnyFrame = true;
    _lastFrame = frame;

    final wasTracking = _tracking;

    _tracking = frame.trackingReliable;
    _trackingReason = frame.trackingReason;

    diagnostics.noteFrame(_now, tracked: _tracking);

    if (wasTracking && !_tracking) {
      diagnostics.noteEvent('tracking lost: '
          '${_trackingReason.isEmpty ? 'unknown' : _trackingReason}');
    } else if (!wasTracking && _tracking) {
      diagnostics.noteEvent('tracking normal again');
    }

    // Points placed while tracking is limited sit against a drifting world,
    // and a face locked then would be in the wrong place by the time the
    // user reached the far end. Such frames are simply not used.
    if (!_tracking) {
      _lastAttempt = null;
      return null;
    }

    return switch (_step) {
      ScanStep.nearEnd => _onNearEndFrame(frame),
      ScanStep.walk => _onWalkFrame(frame),
      ScanStep.farEnd => _onFarEndFrame(frame),
      ScanStep.finished => null,
    };
  }

  /// One attempt at a face, aimed where the user asked -- the middle of the
  /// screen unless they tapped somewhere else.
  FaceAttempt _detect(DepthFrame frame) {
    final seed = _seedFor(frame);

    final attempt = FaceScanner.detect(
      frame,
      seedX: seed?.x,
      seedY: seed?.y,
    );

    diagnostics.noteAttempt(attempt);

    return attempt;
  }

  ScanEvent? _onNearEndFrame(DepthFrame frame) {
    final attempt = _detect(frame);
    _lastAttempt = attempt;

    final face = attempt.face;
    if (face != null) _candidates.add(_Candidate(face, _now));

    final locked = _tryLock();
    if (locked == null) return null;

    _nearFace = locked;
    _step = ScanStep.walk;
    _resetCandidates();
    _lastAttempt = null;
    _aimWorld = null;

    diagnostics.noteEvent('near end locked: ${_describe(locked)}');

    return ScanEvent.nearEndLocked;
  }

  static String _describe(FaceScan face) =>
      'girth ${(face.girthMetres * 100).toStringAsFixed(1)} cm, '
      'distance ${face.distanceMetres.toStringAsFixed(2)} m, '
      'tilt ${face.tiltDegrees.toStringAsFixed(0)} deg, '
      'flat ${face.flatnessMm.toStringAsFixed(1)} mm, '
      'curve ${face.curvaturePerMetre.toStringAsFixed(2)}/m, '
      '${face.pointCount} px';

  ScanEvent? _onWalkFrame(DepthFrame frame) {
    _updateAlong(frame);

    // Turning round at the far end is enough: the moment its face comes into
    // view the scan moves on, without the user having to say so.
    final attempt = FaceScanner.detect(frame);
    final face = attempt.face;

    if (face != null) {
      final check = _checkFarEnd(face);

      if (check.verdict == FarEndVerdict.accepted) {
        _step = ScanStep.farEnd;
        _lastAttempt = attempt;
        _farCheck = check;
        _candidates.add(_Candidate(face, _now));

        diagnostics.noteEvent('far end found while walking: $check');
        return ScanEvent.farEndFound;
      }
    }

    _lastAttempt = null;
    _sampleTrunk(frame);

    return null;
  }

  ScanEvent? _onFarEndFrame(DepthFrame frame) {
    _updateAlong(frame);

    final attempt = _detect(frame);
    _lastAttempt = attempt;

    final face = attempt.face;

    if (face == null) {
      _farCheck = null;
    } else {
      final check = _checkFarEnd(face);
      _farCheck = check;

      // Log each change of mind once, with its numbers: this is the line that
      // says why a far end that looked right to the user was turned down.
      if (check.verdict != _loggedVerdict) {
        _loggedVerdict = check.verdict;
        diagnostics.noteEvent('far end candidate: $check');
      }

      if (check.verdict == FarEndVerdict.accepted) {
        _candidates.add(_Candidate(face, _now));
      }
    }

    final locked = _tryLock();
    if (locked == null) return null;

    _farFace = locked;
    _step = ScanStep.finished;
    _resetCandidates();

    diagnostics.noteEvent('far end locked: ${_describe(locked)}');

    return ScanEvent.finished;
  }

  void _sampleTrunk(DepthFrame frame) {
    final near = _nearFace;
    final axis = _axis;
    if (near == null || axis == null) return;

    final readings = TrunkProfiler.sample(
      frame,
      origin: near.centre,
      axis: axis,
      maxFaceWidthMetres: near.outline.maxWidthMetres,
    );

    if (_samples.length + readings.length > maxTrunkSamples) return;
    _samples.addAll(readings);
  }

  /// Where the middle of the screen is along the log, and whether it is on
  /// the log at all.
  void _updateAlong(DepthFrame frame) {
    final near = _nearFace;
    final axis = _axis;
    if (near == null || axis == null) return;

    final cx = frame.width ~/ 2;
    final cy = frame.height ~/ 2;

    final depth = frame.medianDepthAround(cx, cy);
    if (depth == null) {
      _along = null;
      _offTheLog = true;
      return;
    }

    final point = frame.toWorld(frame.cameraPointAt(cx, cy, depth));
    final offset = point - near.centre;

    final along = offset.dot(axis);
    final sideways = (offset - axis * along).length;

    final allowance = near.outline.maxWidthMetres * 0.75 +
        farEndOffsetAllowanceMetres +
        farEndOffsetPerMetre * along.abs();

    _offTheLog = sideways > allowance || along < -0.3;
    _along = along < 0 ? 0 : along;

    if (!_offTheLog && along > _furthestAlongOnLog) {
      _furthestAlongOnLog = along;
    }
  }

  /// Whether a face is the far end of the log whose near end is already
  /// known, and if not, why not.
  FarEndCheck _checkFarEnd(FaceScan face) {
    final near = _nearFace;
    final axis = _axis;

    if (near == null || axis == null) {
      return const FarEndCheck(
        verdict: FarEndVerdict.sameEnd,
        separationMetres: 0,
        alongMetres: 0,
        sidewaysMetres: 0,
        facing: 1,
        allowedSidewaysMetres: 0,
      );
    }

    final offset = face.centre - near.centre;
    final separation = offset.length;
    final along = offset.dot(axis);
    final sideways = (offset - axis * along).length;
    final facing = face.normal.dot(near.normal);

    final allowed = farEndOffsetAllowanceMetres + farEndOffsetPerMetre * along.abs();

    FarEndCheck check(FarEndVerdict verdict) => FarEndCheck(
          verdict: verdict,
          separationMetres: separation,
          alongMetres: along,
          sidewaysMetres: sideways,
          facing: facing,
          allowedSidewaysMetres: allowed,
        );

    // The first end again. Its centre lands within a few centimetres of where
    // it was; nothing else does.
    if (separation < sameEndMetres) return check(FarEndVerdict.sameEnd);

    // The far end faces the other way. Two angled chainsaw cuts can bring the
    // normals forty degrees off opposite, so the test is loose.
    if (facing > oppositeFacingLimit) {
      return check(FarEndVerdict.facingTheSameWay);
    }

    if (along < minLengthMetres) return check(FarEndVerdict.tooClose);

    if (sideways > allowed) return check(FarEndVerdict.offTheLine);

    return check(FarEndVerdict.accepted);
  }

  /// Returns a face to accept, once the recent readings agree on one.
  FaceScan? _tryLock() {
    _candidates.removeWhere((c) => _now - c.time > lockWindowSeconds);

    final steady = _steadyCandidates();

    if (steady == null) {
      _steadySince = null;
      return null;
    }

    _steadySince ??= _now;

    final latest = steady.last.face;
    final square = latest.tiltDegrees <= squareTiltDegrees;
    final waitedLongEnough = _now - _steadySince! >= patienceSeconds;

    if (!square && !waitedLongEnough) return null;

    return _representative(steady);
  }

  /// The recent readings that agree with one another, if there are enough.
  ///
  /// Agreement is with the *middle* reading, not with every other one, and it
  /// does not need the readings to be consecutive frames: a frame that found
  /// nothing between two that did leaves the count where it was.
  List<_Candidate>? _steadyCandidates() {
    _agreeing = math.min(_candidates.length, lockReadings - 1);

    if (_candidates.length < lockReadings) return null;

    final recent = _candidates.length > 2 * lockReadings
        ? _candidates.sublist(_candidates.length - 2 * lockReadings)
        : List<_Candidate>.of(_candidates);

    final girths = recent.map((c) => c.face.girthMetres).toList()..sort();
    final median = girths[girths.length ~/ 2];

    if (median <= 0) return null;

    var agreeing = recent
        .where((c) => (c.face.girthMetres - median).abs() / median <=
            lockGirthAgreement)
        .toList();

    if (agreeing.length < lockReadings) {
      _agreeing = agreeing.length;
      return null;
    }

    var mean = Vector3.zero();
    for (final c in agreeing) {
      mean += c.face.centre;
    }
    mean.scale(1 / agreeing.length);

    agreeing = agreeing
        .where((c) => (c.face.centre - mean).length <= lockCentreAgreementMetres)
        .toList();

    _agreeing = agreeing.length;

    return agreeing.length >= lockReadings ? agreeing : null;
  }

  /// The reading in the middle of the agreeing set, so neither the highest
  /// nor the lowest frame decides the girth.
  static FaceScan _representative(List<_Candidate> set) {
    final sorted = [...set]
      ..sort((a, b) => a.face.girthMetres.compareTo(b.face.girthMetres));

    return sorted[sorted.length ~/ 2].face;
  }

  void _resetCandidates() {
    _candidates.clear();
    _steadySince = null;
    _agreeing = 0;
    _farCheck = null;
    _loggedVerdict = null;
  }

  // --- What the user can press ------------------------------------------

  /// Whether "Use this" can be offered: a face is in view and would be
  /// accepted if the user vouched for it.
  bool get canUseCurrentFace {
    final face = currentFace;
    if (face == null) return false;

    if (_step == ScanStep.farEnd) {
      // The user may vouch for an end the geometry doubts -- another log's
      // end that is off to one side, or one that faces oddly -- because they
      // can see the log and the scanner cannot. What they cannot vouch for is
      // the first end again, or a face so close to it there is no length.
      final verdict = _checkFarEnd(face).verdict;
      return verdict != FarEndVerdict.sameEnd &&
          verdict != FarEndVerdict.tooClose;
    }

    return _step == ScanStep.nearEnd;
  }

  /// Accepts the face in view now, without waiting for it to settle.
  ScanEvent? useCurrentFace() {
    if (!canUseCurrentFace) return null;

    final face = currentFace!;

    // Prefer the settled middle reading if there are enough of them; the one
    // on screen this instant is merely the most recent.
    final recent = _candidates.length >= 3
        ? _representative(_candidates.sublist(_candidates.length - 3))
        : face;

    if (_step == ScanStep.nearEnd) {
      _nearFace = recent;
      _step = ScanStep.walk;
      _resetCandidates();
      _lastAttempt = null;
      _aimWorld = null;

      diagnostics.noteEvent('near end taken by "Use this end": '
          '${_describe(recent)}');

      return ScanEvent.nearEndLocked;
    }

    final check = _checkFarEnd(recent);
    _farEndVouched = check.verdict != FarEndVerdict.accepted;

    diagnostics.noteEvent('far end taken by "Use this end"'
        '${_farEndVouched ? ' against the geometry' : ''}: $check');

    _farFace = recent;
    _step = ScanStep.finished;
    _resetCandidates();
    return ScanEvent.finished;
  }

  /// The user says they are at the far end. Moves the screen on to asking
  /// for the far face, so they are not left reading "walk" while standing
  /// still in front of it.
  void atFarEnd() {
    if (_step != ScanStep.walk) return;

    _step = ScanStep.farEnd;
    _resetCandidates();

    diagnostics.noteEvent('"I am at the other end" pressed');
  }

  /// Whether the far end can be marked by eye: the user has aimed at the log
  /// far enough from the near end for there to be a length to report.
  bool get canMarkFarEnd =>
      (_step == ScanStep.walk || _step == ScanStep.farEnd) &&
      _furthestAlongOnLog >= minLengthMetres;

  /// Ends the scan at the furthest point along the log the user aimed at,
  /// for a far end that cannot be scanned. The length is then an estimate,
  /// and the result says so.
  ScanEvent? markFarEndHere() {
    if (!canMarkFarEnd) return null;

    _lengthEstimated = true;
    _estimatedLength = _furthestAlongOnLog;
    _farFace = null;
    _step = ScanStep.finished;
    _resetCandidates();

    diagnostics.noteEvent('far end marked by eye at '
        '${_furthestAlongOnLog.toStringAsFixed(2)} m');

    return ScanEvent.finished;
  }

  /// Back to the beginning. Also what an interrupted camera session calls:
  /// the world the near end was located in no longer exists.
  void startOver() {
    diagnostics.noteEvent('start over');

    _step = ScanStep.nearEnd;
    _nearFace = null;
    _farFace = null;
    _farEndVouched = false;
    _aimWorld = null;
    _aimOnScreen = true;
    _lengthEstimated = false;
    _estimatedLength = null;
    _samples.clear();
    _lastAttempt = null;
    _along = null;
    _furthestAlongOnLog = 0;
    _offTheLog = false;
    _resetCandidates();
  }

  // --- The result ---------------------------------------------------------

  LogScanResult? get result {
    if (_step != ScanStep.finished) return null;

    final near = _nearFace;
    if (near == null) return null;

    final far = _farFace;

    final double length;
    var axis = _axis!;

    if (far != null) {
      final span = far.centre - near.centre;
      length = span.length;

      // With both ends known the axis is no longer a guess from one face's
      // normal -- which a slanted cut would have tilted -- but the line
      // between them.
      if (length > 1e-6) axis = span.normalized();
    } else {
      length = _estimatedLength ?? 0;
    }

    final samples = [
      for (final s in _samples)
        s.restatedAgainst(origin: near.centre, axis: axis),
    ];

    final model = LogGirthModel(
      nearFace: near,
      farFace: far,
      lengthMetres: length,
      samples: samples,
      farEndEstimated: far == null,
    );

    return LogScanResult(
      nearFace: near,
      farFace: far,
      lengthMetres: length,
      lengthEstimated: _lengthEstimated,
      minimumGirth: model.minimumGirth,
      profile: model.profile,
      trunkReadings: samples.length,
    );
  }

  // --- Aim ----------------------------------------------------------------

  /// Points the scanner at a place on the screen, as a pixel of the depth
  /// frame. In a yard with a hundred ends in view the middle of the screen is
  /// a poor way to choose one; a tap is better, and it has to keep pointing
  /// at the same end while the phone moves, so it is held as a point in the
  /// world.
  ///
  /// Returns false if the frame has no reading there.
  bool aimAtPixel(int x, int y) {
    final frame = _lastFrame;
    if (frame == null) return false;

    final depth = frame.medianDepthAround(x, y);
    if (depth == null) return false;

    _aimWorld = frame.toWorld(frame.cameraPointAt(x, y, depth));
    _aimOnScreen = true;
    _candidates.clear();
    _agreeing = 0;

    diagnostics.noteEvent('aim set at pixel $x,$y, '
        '${depth.toStringAsFixed(2)} m away');

    return true;
  }

  /// The same, for a tap the native side has resolved to a place in the image:
  /// [u] across and [v] down, each 0..1.
  bool aimAtImagePoint(double u, double v) {
    final frame = _lastFrame;
    if (frame == null) return false;

    return aimAtPixel(
      (u * frame.width).round().clamp(0, frame.width - 1).toInt(),
      (v * frame.height).round().clamp(0, frame.height - 1).toInt(),
    );
  }

  /// Which way the aimed-at point faces the camera, for drawing a marker that
  /// is turned towards the user.
  Vector3? get aimFacing {
    final frame = _lastFrame;
    final world = _aimWorld;
    if (frame == null || world == null) return null;

    final toCamera = frame.cameraPosition - world;
    return toCamera.length < 1e-6 ? null : toCamera.normalized();
  }

  void clearAim() {
    if (_aimWorld != null) diagnostics.noteEvent('aim cleared');

    _aimWorld = null;
    _aimOnScreen = true;
    _candidates.clear();
    _agreeing = 0;
  }

  /// The pixel the scanner looks at this frame: where the aimed-at point has
  /// moved to, or null for the middle of the frame.
  ({int x, int y})? _seedFor(DepthFrame frame) {
    final world = _aimWorld;
    if (world == null) return null;

    final camera = Matrix4.inverted(frame.cameraTransform).transformed3(world);

    if (camera.z >= -0.05) {
      _aimOnScreen = false;
      return null;
    }

    final x = (frame.cx + frame.fx * camera.x / -camera.z).round();
    final y = (frame.cy - frame.fy * camera.y / -camera.z).round();

    // A margin: a seed on the very edge has no patch to fit.
    if (x < 3 || y < 3 || x >= frame.width - 3 || y >= frame.height - 3) {
      _aimOnScreen = false;
      return null;
    }

    _aimOnScreen = true;
    return (x: x, y: y);
  }

  // --- Report -------------------------------------------------------------

  /// A plain-text account of the scan so far, for the user to copy out and
  /// send back after a device test.
  String report() {
    final near = _nearFace;
    final far = _farFace;

    final context = <String>[
      'Step: ${_step.name}',
      'Tracking: ${_tracking ? 'normal' : 'limited ($_trackingReason)'}',
      'Aim: ${_aimWorld == null ? 'middle of screen' : 'tapped, ${_aimOnScreen ? 'on screen' : 'off screen'}'}',
      if (near != null) 'Near end: ${_describe(near)}',
      if (far != null) 'Far end: ${_describe(far)}',
      if (_farCheck != null) 'Far end candidate now: $_farCheck',
      if (_farEndVouched) 'Far end taken against the geometry, on the user\'s word',
      'Trunk readings: ${_samples.length}',
      'Furthest along the log: ${_furthestAlongOnLog.toStringAsFixed(2)} m',
    ];

    final result = this.result;

    if (result != null) {
      context.add('Result: length ${result.lengthMetres.toStringAsFixed(2)} m'
          '${result.lengthEstimated ? ' (estimated)' : ''}, '
          'thinnest girth ${(result.minimumGirth.girthMetres * 100).toStringAsFixed(1)} cm '
          '(${result.minimumGirth.source.name}), '
          'first end ${(result.faceGirthMetres * 100).toStringAsFixed(1)} cm'
          '${result.farFaceGirthMetres == null ? '' : ', other end ${(result.farFaceGirthMetres! * 100).toStringAsFixed(1)} cm'}');
    }

    return diagnostics.report(context: context);
  }

  // --- What to say --------------------------------------------------------

  ScanGuidance get guidance {
    if (!_sawAnyFrame) {
      return const ScanGuidance(
        'Starting the camera…',
        detail: 'Hold the phone up in front of you',
      );
    }

    if (!_tracking && _step != ScanStep.finished) {
      return _trackingGuidance();
    }

    return switch (_step) {
      ScanStep.nearEnd => _faceGuidance(far: false),
      ScanStep.walk => _walkGuidance(),
      ScanStep.farEnd => _faceGuidance(far: true),
      ScanStep.finished => const ScanGuidance(
          'Done',
          detail: 'Girth and length measured',
          tone: GuidanceTone.good,
          progress: 1,
        ),
    };
  }

  ScanGuidance _trackingGuidance() {
    return switch (_trackingReason) {
      'initializing' => const ScanGuidance(
          'Getting ready…',
          detail: 'Move the phone slowly from side to side',
        ),
      'excessiveMotion' => const ScanGuidance(
          'Slow down',
          detail: 'Move the phone more slowly',
          tone: GuidanceTone.warning,
        ),
      'insufficientFeatures' => const ScanGuidance(
          'Too dark or too plain',
          detail: 'Add light, or show more of the ground around the log',
          tone: GuidanceTone.warning,
        ),
      'relocalizing' => const ScanGuidance(
          'Finding its place…',
          detail: 'Point back at where you started',
          tone: GuidanceTone.warning,
        ),
      _ => const ScanGuidance(
          'Hold on…',
          detail: 'Keep the phone steady',
          tone: GuidanceTone.warning,
        ),
    };
  }

  ScanGuidance _walkGuidance() {
    if (_offTheLog) {
      return const ScanGuidance(
        'Point back at the log',
        detail: 'Keep it in the middle of the screen as you walk',
        tone: GuidanceTone.warning,
      );
    }

    return const ScanGuidance(
      'Now walk to the other end',
      detail: 'Keep the log in the middle of the screen',
    );
  }

  ScanGuidance _farEndRefusal(FarEndCheck check) {
    return switch (check.verdict) {
      FarEndVerdict.sameEnd || FarEndVerdict.accepted => const ScanGuidance(
          'That is the end you already scanned',
          detail: 'Go to the other end of the log',
          tone: GuidanceTone.warning,
        ),
      FarEndVerdict.facingTheSameWay => const ScanGuidance(
          'That end faces the same way as the first',
          detail: 'Go round to the far end of the log and point back at it',
          tone: GuidanceTone.warning,
        ),
      FarEndVerdict.tooClose => const ScanGuidance(
          'That is very close to the first end',
          detail: 'The other end should be at least 15 cm along the log',
          tone: GuidanceTone.warning,
        ),
      FarEndVerdict.offTheLine => const ScanGuidance(
          'That end is off to one side of the log',
          detail: 'Is it another log? If it is the right one, tap "Use this end"',
          tone: GuidanceTone.warning,
        ),
    };
  }

  ScanGuidance _faceGuidance({required bool far}) {
    final check = far ? _farCheck : null;

    if (check != null && check.verdict != FarEndVerdict.accepted) {
      return _farEndRefusal(check);
    }

    final attempt = _lastAttempt;
    final face = attempt?.face;

    if (face != null) {
      final progress = lockProgress;

      if (face.tiltDegrees > squareTiltDegrees) {
        return ScanGuidance(
          'Good — now face it straight on',
          detail: 'Stand in front of the end, not to one side',
          tone: GuidanceTone.good,
          progress: progress.toDouble(),
        );
      }

      return ScanGuidance(
        'Hold still…',
        detail: far ? 'Reading the far end' : 'Reading the cut end',
        tone: GuidanceTone.good,
        progress: progress.toDouble(),
      );
    }

    final rejection = attempt?.rejection ?? FaceRejection.noDepth;

    final aimAt = far ? 'Point at the other cut end' : 'Point at the cut end';

    return switch (rejection) {
      FaceRejection.noDepth => ScanGuidance(
          aimAt,
          detail: 'The round, flat end where the log was cut',
        ),
      FaceRejection.tooFar || FaceRejection.tooSmall => const ScanGuidance(
          'Move closer',
          detail: 'About one step away from the end is best',
          tone: GuidanceTone.warning,
        ),
      FaceRejection.tooClose => const ScanGuidance(
          'Move back a little',
          detail: 'About one step away from the end is best',
          tone: GuidanceTone.warning,
        ),
      FaceRejection.runsOffScreen => const ScanGuidance(
          'Step back',
          detail: 'The whole end must fit on the screen',
          tone: GuidanceTone.warning,
        ),
      FaceRejection.pointingAtTheSide => const ScanGuidance(
          'That is the side of the log',
          detail: 'Point at the flat cut end instead',
          tone: GuidanceTone.warning,
        ),
      FaceRejection.notFlat => ScanGuidance(
          aimAt,
          detail: 'The round, flat end where the log was cut',
        ),
      FaceRejection.tooAngled => const ScanGuidance(
          'Face the cut end straight on',
          detail: 'Stand in front of it, not to one side',
          tone: GuidanceTone.warning,
        ),
      FaceRejection.outlineIncomplete => const ScanGuidance(
          'Hold still…',
          detail: 'Finding the edge of the log',
        ),
      FaceRejection.moreThanOneLog => const ScanGuidance(
          'Aim at one log only',
          detail: 'Put the middle of the screen on a single end',
          tone: GuidanceTone.warning,
        ),
    };
  }
}
