import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../models/log_defect.dart';
import '../painters/defect_overlay_painter.dart';
import '../utils/image_quality.dart';
import '../utils/snapshot.dart';
import 'defect_advisor.dart';
import 'defect_detector.dart';
import 'diagnostics_service.dart';
import 'log_face_detector.dart';

/// Where the scan is.
enum ScanPhase { idle, preparing, scanning, done, failed }

/// What a person decided about one finding.
enum FindingReview {
  /// Faint, not yet looked at.
  pending,

  /// A clear detection, or a faint one a person confirmed.
  confirmed,

  /// A person said it is not a defect. It leaves the count and the grade.
  dismissed,
}

/// Decoded photo plus everything worked out from it in the same background
/// hop: its quality, and -- when the photo is of a cut end -- where the face
/// is, so defects can be placed as "heart" or "near the bark".
class _Prepared {
  final img.Image image;
  final ImageQuality quality;
  final double? faceX;
  final double? faceY;
  final double? faceRadius;

  const _Prepared(
    this.image,
    this.quality, {
    this.faceX,
    this.faceY,
    this.faceRadius,
  });
}

class _PrepareRequest {
  final Uint8List bytes;
  final bool findFace;

  const _PrepareRequest(this.bytes, this.findFace);
}

_Prepared? _prepareInBackground(_PrepareRequest request) {
  final raw = img.decodeImage(request.bytes);
  if (raw == null) return null;

  // Phone cameras write pixels sideways with an EXIF tag saying how to turn
  // them. Flutter honours the tag; the image package does not. Without
  // baking it in, a portrait photo is analysed rotated.
  final decoded = img.bakeOrientation(raw);
  final quality = ImageQualityChecker.assess(decoded);

  double? faceX, faceY, faceRadius;

  if (request.findFace && quality.isUsable) {
    // A cut end is usually framed in the middle of the photo. If a clean
    // face is found from there, defects can be placed on it; if not -- a
    // photo along the bark, say -- nothing is claimed about position.
    try {
      final face = LogFaceDetector.detect(
        image: decoded,
        centre: Offset(decoded.width / 2, decoded.height / 2),
      );

      if (face != null && face.isReliable) {
        final e = face.ellipse;
        final radius = math.sqrt(e.semiMajor * e.semiMinor);
        final minSide = math.min(decoded.width, decoded.height);

        // A "face" a tenth of the photo across is a knot or a coin, not the
        // log end the photo was taken of.
        if (radius * 2 >= minSide * 0.35) {
          faceX = e.centre.dx;
          faceY = e.centre.dy;
          faceRadius = radius;
        }
      }
    } catch (_) {}
  }

  return _Prepared(
    decoded,
    quality,
    faceX: faceX,
    faceY: faceY,
    faceRadius: faceRadius,
  );
}

/// One finding with the person's decision about it.
class ReviewedFinding {
  final int number;
  final DefectFinding finding;
  final FindingReview review;
  final AssessedDefect assessed;

  const ReviewedFinding({
    required this.number,
    required this.finding,
    required this.review,
    required this.assessed,
  });

  bool get isActive => review != FindingReview.dismissed;
}

/// Runs a defect scan and holds everything about it: the photo, the model's
/// findings, and what the user decided about each one.
///
/// Shared by the Defect Detection screen and the Log Report builder, so a
/// review made in one is exactly what the other reports.
class DefectScanController extends ChangeNotifier {
  DefectScanController({
    DefectDetector? detector,
    this.findFace = true,
  }) : _detectorOverride = detector;

  final DefectDetector? _detectorOverride;

  /// Whether to look for the cut face automatically when none was traced.
  final bool findFace;

  DefectDetector get detector => _detectorOverride ?? DefectDetection.instance;

  ScanPhase _phase = ScanPhase.idle;
  ScanPhase get phase => _phase;

  File? _file;
  File? get file => _file;

  ui.Image? _photo;
  ui.Image? get photo => _photo;

  Size? _imageSize;
  Size? get imageSize => _imageSize;

  ImageQuality? _quality;
  ImageQuality? get quality => _quality;

  DefectAnalysis? _analysis;
  DefectAnalysis? get analysis => _analysis;

  String? _error;
  String? get error => _error;

  int _passesDone = 0;
  int _passesTotal = 0;

  /// 0..1 while scanning.
  double get progress =>
      _passesTotal == 0 ? 0 : (_passesDone / _passesTotal).clamp(0.0, 1.0);

  int get passesTotal => _passesTotal;

  /// Face in photo pixels -- from a trace when there is one, otherwise found
  /// automatically, otherwise null.
  Offset? _faceCentre;
  double? _faceRadius;
  bool _faceFromTrace = false;

  Offset? get faceCentre => _faceCentre;
  double? get faceRadius => _faceRadius;
  bool get faceFromTrace => _faceFromTrace;
  bool get hasFace => _faceCentre != null && (_faceRadius ?? 0) > 0;

  final Map<int, FindingReview> _reviews = {};

  int? _selected;
  int? get selected => _selected;

  bool get isBusy =>
      _phase == ScanPhase.preparing || _phase == ScanPhase.scanning;

  bool get hasResult => _analysis != null;

  // --- running ---------------------------------------------------------------

  /// Scans [file] from scratch.
  Future<void> scan(File file) async {
    _file = file;
    _photo = null;
    _imageSize = null;
    _quality = null;
    _analysis = null;
    _error = null;
    _reviews.clear();
    _selected = null;
    _passesDone = 0;
    _passesTotal = 0;

    if (!_faceFromTrace) {
      _faceCentre = null;
      _faceRadius = null;
    }

    _phase = ScanPhase.preparing;
    notifyListeners();

    _loadPhoto(file);

    try {
      final bytes = await file.readAsBytes();

      final prepared = await compute(
        _prepareInBackground,
        _PrepareRequest(bytes, findFace && !_faceFromTrace),
      );

      if (prepared == null) {
        _fail("That file isn't an image this app can read.");
        return;
      }

      _quality = prepared.quality;
      _imageSize = Size(
        prepared.image.width.toDouble(),
        prepared.image.height.toDouble(),
      );

      if (!_faceFromTrace && prepared.faceRadius != null) {
        _faceCentre = Offset(prepared.faceX!, prepared.faceY!);
        _faceRadius = prepared.faceRadius;
      }

      // Refuse before inference, not after. A model has no way to say "I
      // cannot see" -- it returns a confident answer for a blurred photo of
      // nothing, and a wrong answer is worse than no answer.
      if (!prepared.quality.isUsable || !detector.isAvailable) {
        _phase = ScanPhase.done;
        notifyListeners();
        return;
      }

      _phase = ScanPhase.scanning;
      notifyListeners();

      final analysis = await DiagnosticsService.instance.timed(
        DiagnosticsService.moduleDefects,
        () => detector.analyse(
          prepared.image,
          onProgress: (done, total) {
            _passesDone = done;
            _passesTotal = total;
            notifyListeners();
          },
        ),
      );

      _analysis = analysis;

      final defects = analysis.defects;
      for (var i = 0; i < defects.length; i++) {
        _reviews[i] = defects[i].isConfident
            ? FindingReview.confirmed
            : FindingReview.pending;
      }

      _phase = ScanPhase.done;
      notifyListeners();
    } catch (error) {
      await DiagnosticsService.instance.recordError(
        module: DiagnosticsService.moduleDefects,
        error: error,
      );

      // The raw exception goes to the diagnostic store, never to the user.
      _fail("Something went wrong reading that photo. Try another one.");
    }
  }

  void _fail(String message) {
    _error = message;
    _phase = ScanPhase.failed;
    notifyListeners();
  }

  /// Loads the photo for painting, through Flutter's own pipeline so the
  /// EXIF interpretation matches what the overlay is drawn against.
  void _loadPhoto(File file) {
    final stream = FileImage(file).resolve(ImageConfiguration.empty);

    late final ImageStreamListener listener;

    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (_file != file) return;
        _photo = info.image;
        notifyListeners();
      },
      onError: (_, __) => stream.removeListener(listener),
    );

    stream.addListener(listener);
  }

  /// Uses a traced face for positions instead of guessing one. Centre and
  /// radius in photo pixels.
  void useTracedFace(Offset centre, double radius) {
    _faceCentre = centre;
    _faceRadius = radius;
    _faceFromTrace = true;
    notifyListeners();
  }

  // --- review ----------------------------------------------------------------

  List<DefectFinding> get _defects => _analysis?.defects ?? const [];

  /// Every finding, numbered in the order they are listed and drawn.
  List<ReviewedFinding> get findings {
    final size = _imageSize ?? const Size(1, 1);
    final list = <ReviewedFinding>[];

    for (var i = 0; i < _defects.length; i++) {
      final finding = _defects[i];
      final review = _reviews[i] ?? FindingReview.pending;

      list.add(
        ReviewedFinding(
          number: i + 1,
          finding: finding,
          review: review,
          assessed: AssessedDefect.locate(
            kind: finding.kind,
            label: finding.displayLabel,
            region: finding.region,
            confirmed: review == FindingReview.confirmed,
            imageSize: size,
            faceCentre: _faceCentre,
            faceRadius: _faceRadius,
          ),
        ),
      );
    }

    return list;
  }

  /// The findings that count: everything not dismissed.
  List<ReviewedFinding> get active => [
        for (final f in findings)
          if (f.isActive) f
      ];

  int get count => active.length;

  int get pendingCount =>
      findings.where((f) => f.review == FindingReview.pending).length;

  int get dismissedCount =>
      findings.where((f) => f.review == FindingReview.dismissed).length;

  /// Confirmed defects in the app's own form, in photo pixels -- what the
  /// cutting engine and the impact analysis consume.
  List<LogDefect> get confirmedDefects => [
        for (final f in findings)
          if (f.review == FindingReview.confirmed)
            f.finding.toDefect().copyWith(
                  // A person stood behind it now, whatever the model said.
                  confidence: math.max(
                    f.finding.confidence,
                    DefectFinding.confidenceThreshold,
                  ),
                ),
      ];

  List<AssessedDefect> get assessed => [for (final f in active) f.assessed];

  GradeResult get grade => LogQualityGrader.grade(assessed);

  List<DefectAdvice> advice({
    double lostCubicFeet = 0,
    double lostValue = 0,
    bool hasTracedFace = false,
  }) =>
      DefectAdvisor.advise(
        defects: assessed,
        hasTracedFace: hasTracedFace || _faceFromTrace,
        lostCubicFeet: lostCubicFeet,
        lostValue: lostValue,
      );

  /// Counts per defect name, most serious kind first.
  List<({String label, LogDefectKind kind, int count})> get breakdown {
    final counts = <String, ({LogDefectKind kind, int count})>{};

    for (final f in active) {
      final label = f.finding.displayLabel;
      final current = counts[label];
      counts[label] = (
        kind: f.finding.kind,
        count: (current?.count ?? 0) + 1,
      );
    }

    final list = [
      for (final e in counts.entries)
        (label: e.key, kind: e.value.kind, count: e.value.count),
    ]..sort((a, b) => b.kind.severity.compareTo(a.kind.severity));

    return list;
  }

  void confirm(int index) => _set(index, FindingReview.confirmed);

  void dismiss(int index) => _set(index, FindingReview.dismissed);

  /// Undoes a dismissal: back to whatever the scan originally thought.
  void restore(int index) {
    if (index < 0 || index >= _defects.length) return;
    _set(
      index,
      _defects[index].isConfident
          ? FindingReview.confirmed
          : FindingReview.pending,
    );
  }

  void _set(int index, FindingReview review) {
    if (index < 0 || index >= _defects.length) return;
    _reviews[index] = review;
    notifyListeners();
  }

  void select(int? index) {
    _selected = _selected == index ? null : index;
    notifyListeners();
  }

  // --- drawing ---------------------------------------------------------------

  List<OverlayMark> marks(
      {bool includeDismissed = true, bool highlight = true}) {
    final all = findings;

    return [
      for (var i = 0; i < all.length; i++)
        if (includeDismissed || all[i].isActive)
          OverlayMark(
            region: all[i].finding.region,
            number: all[i].number,
            label: all[i].finding.displayLabel,
            colour: DefectOverlayPainter.colourForKind(all[i].finding.kind),
            pending: all[i].review == FindingReview.pending,
            dismissed: all[i].review == FindingReview.dismissed,
            selected: highlight && _selected == i,
          ),
    ];
  }

  /// The photo with its marks, as a PNG for the report. [extraMarks] adds
  /// defects marked by hand, numbered on from the scan's own.
  Future<Uint8List?> renderOverlay({
    int longestSide = 1400,
    List<OverlayMark> extraMarks = const [],
  }) async {
    final photo = _photo;
    final size = _imageSize ??
        (photo == null
            ? null
            : Size(photo.width.toDouble(), photo.height.toDouble()));
    if (photo == null || size == null) return null;

    final scale = longestSide / math.max(size.width, size.height);
    final target = Size(size.width * scale, size.height * scale);

    // Renumbered 1..n: the report lists only the defects that count, so the
    // photo must not skip the numbers of dismissed ones.
    final all = [
      ...marks(includeDismissed: false, highlight: false),
      ...extraMarks,
    ];

    final numbered = [
      for (var i = 0; i < all.length; i++)
        OverlayMark(
          region: all[i].region,
          number: i + 1,
          label: all[i].label,
          colour: all[i].colour,
          pending: all[i].pending,
        ),
    ];

    return paintToPng(
      DefectOverlayPainter(
        photo: photo,
        imageSize: size,
        marks: numbered,
        faceCentre: _faceCentre,
        faceRadius: _faceRadius,
        strokeScale: math.max(1.0, target.shortestSide / 420),
      ),
      target,
    );
  }
}
