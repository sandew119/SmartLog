import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../models/log_measurement.dart';
import 'depth_frame.dart';
import 'face_scan.dart';
import 'log_girth_model.dart';
import 'log_volume_pipeline.dart';

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

  /// Frames that must agree before a face is accepted.
  static const int lockReadings = 4;

  /// How recent those frames must be, in seconds.
  static const double lockWindowSeconds = 1.2;

  /// How closely their girths must agree, as a fraction.
  static const double lockGirthAgreement = 0.03;

  /// How far apart their centres may be.
  static const double lockCentreAgreementMetres = 0.025;

  /// Square enough to lock at once. The detector itself accepts up to 45
  /// degrees; between the two the user is asked to straighten up.
  static const double squareTiltDegrees = 35;

  /// After this long holding a steady face that is not quite square, take it.
  static const double patienceSeconds = 3.5;

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

  final List<TrunkWidthSample> _samples = [];

  FaceAttempt? _lastAttempt;
  bool _wrongEnd = false;

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
  FaceScan? get currentFace =>
      (_step == ScanStep.nearEnd || _step == ScanStep.farEnd) && !_wrongEnd
          ? _lastAttempt?.face
          : null;

  /// How far along the log the middle of the screen is, in metres from the
  /// near end.
  double? get alongMetres => _along;

  /// The furthest point along the log the user has aimed at.
  double get furthestAlongMetres => _furthestAlongOnLog;

  int get trunkReadings => _samples.length;

  bool get trackingReliable => _tracking;

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

    _tracking = frame.trackingReliable;
    _trackingReason = frame.trackingReason;

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

  ScanEvent? _onNearEndFrame(DepthFrame frame) {
    final attempt = FaceScanner.detect(frame);
    _lastAttempt = attempt;

    final face = attempt.face;
    if (face != null) _candidates.add(_Candidate(face, _now));

    final locked = _tryLock();
    if (locked == null) return null;

    _nearFace = locked;
    _step = ScanStep.walk;
    _resetCandidates();
    _lastAttempt = null;

    return ScanEvent.nearEndLocked;
  }

  ScanEvent? _onWalkFrame(DepthFrame frame) {
    _updateAlong(frame);

    // Turning round at the far end is enough: the moment its face comes into
    // view the scan moves on, without the user having to say so.
    final attempt = FaceScanner.detect(frame);
    final face = attempt.face;

    if (face != null && _isFarEnd(face)) {
      _step = ScanStep.farEnd;
      _lastAttempt = attempt;
      _wrongEnd = false;
      _candidates.add(_Candidate(face, _now));
      return ScanEvent.farEndFound;
    }

    _lastAttempt = null;
    _sampleTrunk(frame);

    return null;
  }

  ScanEvent? _onFarEndFrame(DepthFrame frame) {
    _updateAlong(frame);

    final attempt = FaceScanner.detect(frame);
    _lastAttempt = attempt;

    final face = attempt.face;

    if (face == null) {
      _wrongEnd = false;
    } else if (_isFarEnd(face)) {
      _wrongEnd = false;
      _candidates.add(_Candidate(face, _now));
    } else {
      // A face, but facing the same way as the one already scanned: the user
      // is looking at the near end again, or at the end of another log.
      _wrongEnd = true;
    }

    final locked = _tryLock();
    if (locked == null) return null;

    _farFace = locked;
    _step = ScanStep.finished;
    _resetCandidates();

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

  /// Whether a face could be the far end of the log whose near end is
  /// already known.
  bool _isFarEnd(FaceScan face) {
    final near = _nearFace;
    final axis = _axis;
    if (near == null || axis == null) return false;

    // The far end faces the other way. Two angled chainsaw cuts can bring
    // the normals twenty degrees or more off opposite, so the test is loose.
    if (face.normal.dot(near.normal) > -0.6) return false;

    final offset = face.centre - near.centre;
    final along = offset.dot(axis);

    if (along < minLengthMetres) return false;

    final sideways = (offset - axis * along).length;

    return sideways <=
        farEndOffsetAllowanceMetres + farEndOffsetPerMetre * along;
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

  List<_Candidate>? _steadyCandidates() {
    if (_candidates.length < lockReadings) return null;

    final recent = _candidates.sublist(_candidates.length - lockReadings);

    final girths = recent.map((c) => c.face.girthMetres).toList()..sort();
    final median = girths[girths.length ~/ 2];

    if (median <= 0) return null;
    if ((girths.last - girths.first) / median > lockGirthAgreement) {
      return null;
    }

    var mean = Vector3.zero();
    for (final c in recent) {
      mean += c.face.centre;
    }
    mean.scale(1 / recent.length);

    for (final c in recent) {
      if ((c.face.centre - mean).length > lockCentreAgreementMetres) {
        return null;
      }
    }

    return recent;
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
    _wrongEnd = false;
  }

  // --- What the user can press ------------------------------------------

  /// Whether "Use this" can be offered: a face is in view and would be
  /// accepted if the user vouched for it.
  bool get canUseCurrentFace {
    final face = currentFace;
    if (face == null) return false;
    if (_step == ScanStep.farEnd) return _isFarEnd(face);
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
      return ScanEvent.nearEndLocked;
    }

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

    return ScanEvent.finished;
  }

  /// Back to the beginning. Also what an interrupted camera session calls:
  /// the world the near end was located in no longer exists.
  void startOver() {
    _step = ScanStep.nearEnd;
    _nearFace = null;
    _farFace = null;
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

  ScanGuidance _faceGuidance({required bool far}) {
    if (far && _wrongEnd) {
      return const ScanGuidance(
        'That is the end you already scanned',
        detail: 'Go to the other end of the log',
        tone: GuidanceTone.warning,
      );
    }

    final attempt = _lastAttempt;
    final face = attempt?.face;

    if (face != null) {
      final progress = (_candidates.length / lockReadings).clamp(0.0, 1.0);

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
