import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../models/log_measurement.dart';
import '../services/lidar_scanner_service.dart';
import '../services/user_preferences_service.dart';
import '../utils/depth_frame.dart';
import '../utils/face_scan.dart';
import '../utils/log_girth_model.dart';
import '../utils/log_scan_session.dart';
import '../utils/log_volume_pipeline.dart';
import '../utils/outline_ribbon.dart';
import '../utils/timber_volume.dart';
import '../utils/unit_display.dart';

/// Measures a log with LiDAR in three steps: point at one cut end, walk to
/// the other, point at that one.
///
/// While it works, the app draws what it is measuring: a ribbon round the cut
/// end that turns from white to amber to green as the readings settle, so the
/// user can see it has found the right thing and is working on it -- and a tap
/// on any end in view chooses it, for a yard with a hundred in sight.
///
/// Built for someone who has never used a scanning app and does not want to
/// learn one. There is one instruction on screen at a time, in plain words,
/// in large type. Nothing needs tapping to make the scan work -- the app
/// finds each end by itself, says so out loud, and buzzes. The buttons that
/// exist are ways out for when something cannot be done, not steps in the
/// normal flow.
///
/// All judgement lives in [LogScanSession]; this screen shows what it says.
/// Returns a [LogMeasurement] via `Navigator.pop`, or null if the user backed
/// out.
class LogScannerScreen extends StatefulWidget {
  const LogScannerScreen({super.key});

  @override
  State<LogScannerScreen> createState() => _LogScannerScreenState();
}

class _LogScannerScreenState extends State<LogScannerScreen> {
  final LogScanSession _session = LogScanSession();
  final LidarScannerService _service = LidarScannerService.instance;

  int? _viewId;
  MethodChannel? _channel;

  bool _streaming = false;
  String? _cameraProblem;

  String? _toast;
  Timer? _toastTimer;

  bool _liveOutlineShown = false;
  bool _aimShown = false;
  double _lastProgress = 0;

  @override
  void dispose() {
    _toastTimer?.cancel();
    _channel?.setMethodCallHandler(null);

    final id = _viewId;
    if (id != null) _service.stopStreaming(id);

    super.dispose();
  }

  // --- Native link ------------------------------------------------------

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel("smartlog/lidar_scanner/view_$id");
    channel.setMethodCallHandler(_onNative);

    _channel = channel;
    _viewId = id;

    _startStreaming();
  }

  void _startStreaming() {
    final id = _viewId;
    if (id == null || _streaming) return;

    _streaming = true;
    _service.startStreaming(id);
  }

  void _stopStreaming() {
    final id = _viewId;
    if (id == null || !_streaming) return;

    _streaming = false;
    _service.stopStreaming(id);
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (!mounted) return null;

    switch (call.method) {
      case "frame":
        _onFrame(call.arguments);

      case "sessionFailed":
        final args = call.arguments;
        setState(() {
          _cameraProblem = args is Map && args["message"] is String
              ? args["message"] as String
              : "The camera stopped working.";
        });

      case "sessionInterrupted":
        setState(() => _cameraProblem = "Camera paused — hold on");

      case "sessionResumed":
        // The world the first end was found in is gone: the phone could have
        // been anywhere while the camera was off. Carrying on would measure
        // a length between two places that no longer relate to each other.
        final hadProgress = _session.step != ScanStep.nearEnd;

        _session.startOver();
        _clearMarkers();

        setState(() => _cameraProblem = null);

        if (hadProgress) {
          _showToast("Camera restarted — scan the first end again");
        }
    }

    return null;
  }

  void _onFrame(Object? arguments) {
    final id = _viewId;

    try {
      if (arguments is! Map || _session.step == ScanStep.finished) return;

      final frame = DepthFrame.fromNative(
        Map<Object?, Object?>.from(arguments),
      );
      if (frame == null) return;

      final watch = Stopwatch()..start();
      final event = _session.onFrame(frame);
      watch.stop();

      _session.diagnostics.noteProcessing(watch.elapsedMicroseconds / 1000);

      setState(() => _cameraProblem = null);

      _updateOverlays();

      if (event != null) _onEvent(event);
    } finally {
      // Always, even if this frame was useless: the native side will not send
      // another until it hears back.
      if (id != null && _streaming) _service.ackFrame(id);
    }
  }

  void _onEvent(ScanEvent event) {
    switch (event) {
      case ScanEvent.nearEndLocked:
        HapticFeedback.heavyImpact();

        _dropLiveOverlays();

        final face = _session.nearFace;
        if (face != null) _markFace("near", face);

        _say("Face scan complete. Now walk to the other end.");
        _showToast("Face scan complete");

      case ScanEvent.farEndFound:
        HapticFeedback.selectionClick();

      case ScanEvent.finished:
        HapticFeedback.heavyImpact();

        _dropLiveOverlays();

        final face = _session.farFace;
        if (face != null) _markFace("far", face);

        _say("Length complete.");
        _showToast("Length complete");

        // Nothing more to read; the camera can rest while they look at the
        // numbers.
        _stopStreaming();
    }

    setState(() {});
  }

  void _markFace(String id, FaceScan face) {
    final viewId = _viewId;
    if (viewId == null) return;

    _service.showMarker(
      viewId,
      id: id,
      position: face.centre,
      normal: face.normal,
      radius: face.diameterMetres / 2,
    );

    // The outline it measured, kept on the end as proof of what was measured.
    _drawOutline(id, face, _goodColour);
  }

  void _clearMarkers() {
    final id = _viewId;
    if (id != null) _service.clearMarkers(id);

    _liveOutlineShown = false;
    _aimShown = false;
    _lastProgress = 0;
  }

  void _drawOutline(String id, FaceScan face, Color colour) {
    final viewId = _viewId;
    if (viewId == null) return;

    _service.showOutline(
      viewId,
      id: id,
      vertices: OutlineRibbon.strip(
        face.outlinePoints(),
        face.normal,
        OutlineRibbon.halfWidthFor(face.distanceMetres),
      ),
      red: colour.r,
      green: colour.g,
      blue: colour.b,
    );
  }

  /// Keeps what is drawn on the log in step with what the scanner sees: the
  /// outline it is measuring right now, coloured by how settled the reading
  /// is, and a tick under the thumb each time another reading agrees.
  void _updateOverlays() {
    final viewId = _viewId;
    if (viewId == null) return;

    final step = _session.step;
    final face = (step == ScanStep.nearEnd || step == ScanStep.farEnd)
        ? _session.currentFace
        : null;

    if (face == null) {
      if (_liveOutlineShown) {
        _service.clearOutline(viewId, "live");
        _liveOutlineShown = false;
      }

      _lastProgress = 0;
    } else {
      final progress = _session.lockProgress;

      final colour = progress >= 1
          ? _goodColour
          : (progress > 0.3 ? _measuringColour : Colors.white);

      _drawOutline("live", face, colour);
      _liveOutlineShown = true;

      // One tick for each new reading that agrees: the phone's way of saying
      // "still working on it".
      if (progress > _lastProgress && progress < 1) {
        HapticFeedback.selectionClick();
      }

      _lastProgress = progress;
    }

    if (!_session.hasAim && _aimShown) {
      _service.clearOutline(viewId, "aim");
      _aimShown = false;
    }
  }

  void _dropLiveOverlays() {
    final viewId = _viewId;
    if (viewId == null) return;

    _service.clearOutline(viewId, "live");
    _service.clearOutline(viewId, "aim");

    _liveOutlineShown = false;
    _aimShown = false;
    _lastProgress = 0;
  }

  // --- Choosing an end ----------------------------------------------------

  /// A tap on the picture picks the end under the finger. In a yard with a
  /// hundred logs in view the middle of the screen is a poor way to choose one.
  Future<void> _onTapView(Offset at, Size size) async {
    final viewId = _viewId;
    if (viewId == null || size.width <= 0 || size.height <= 0) return;

    final step = _session.step;
    if (step != ScanStep.nearEnd && step != ScanStep.farEnd) return;

    final place = await _service.viewToImage(
      viewId,
      x: at.dx / size.width,
      y: at.dy / size.height,
    );

    if (!mounted) return;

    if (place == null || !_session.aimAtImagePoint(place.u, place.v)) {
      _showToast("Nothing to measure there");
      return;
    }

    HapticFeedback.selectionClick();
    _drawAimRing();

    setState(() {});
  }

  /// A small ring on the chosen spot, held in the world so it stays put.
  void _drawAimRing() {
    final viewId = _viewId;
    final centre = _session.aimPoint;
    final facing = _session.aimFacing;

    if (viewId == null || centre == null || facing == null) return;

    final basis = perpendicularBasis(facing);
    const radius = 0.035;

    final ring = <Vector3>[
      for (var i = 0; i < 24; i++)
        centre +
            basis.u * (radius * math.cos(2 * math.pi * i / 24)) +
            basis.v * (radius * math.sin(2 * math.pi * i / 24)),
    ];

    _service.showOutline(
      viewId,
      id: "aim",
      vertices: OutlineRibbon.strip(ring, facing, 0.004),
      red: 1,
      green: 1,
      blue: 1,
    );

    _aimShown = true;
  }

  void _useMiddleAgain() {
    final viewId = _viewId;

    _session.clearAim();

    if (viewId != null) _service.clearOutline(viewId, "aim");
    _aimShown = false;

    setState(() {});
  }

  void _say(String text) {
    final id = _viewId;
    if (id != null) _service.speak(id, text);
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);

    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // --- User actions -----------------------------------------------------

  void _useThisEnd() {
    final event = _session.useCurrentFace();
    if (event != null) _onEvent(event);
  }

  void _atOtherEnd() {
    setState(_session.atFarEnd);
  }

  void _markFarEnd() {
    final event = _session.markFarEndHere();
    if (event != null) _onEvent(event);
  }

  void _startOver() {
    _session.startOver();
    _clearMarkers();
    _startStreaming();

    setState(() {});
  }

  void _finish() {
    final result = _session.result;
    if (result == null) return;

    Navigator.pop(context, result.toMeasurement());
  }

  /// The scan's own account of itself -- frames, rejections, the numbers behind
  /// every decision -- as text to send back after a device test.
  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _session.report()));

    if (!mounted) return;
    _showToast("Scan report copied");
  }

  void _showReport() {
    final report = _session.report();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: const Text(
          "Scan report",
          style: TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: "Courier",
                fontSize: 11,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report));
              Navigator.pop(context);
              _showToast("Scan report copied");
            },
            child: const Text("Copy"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  // --- Layout -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final step = _session.step;
    final result = step == ScanStep.finished ? _session.result : null;

    final guidance = _cameraProblem != null
        ? ScanGuidance(_cameraProblem!, tone: GuidanceTone.warning)
        : _session.guidance;

    final aimingAtAFace = step == ScanStep.nearEnd || step == ScanStep.farEnd;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Exactly one of these. Each creates its own ARSession, and a second
          // session pauses the first.
          Positioned.fill(
            child: UiKitView(
              viewType: LidarScannerService.platformViewType,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onPlatformViewCreated,
            ),
          ),

          // Above the camera and below everything else: a tap on the picture
          // chooses the end under it.
          if (result == null && aimingAtAFace)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, box) => GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (details) =>
                      _onTapView(details.localPosition, box.biggest),
                ),
              ),
            ),

          if (result == null && aimingAtAFace && !_session.hasAim)
            Center(
              child: _FaceReticle(
                progress: guidance.progress ?? 0,
                seeingFace: _session.currentFace != null,
              ),
            ),

          if (result == null && step == ScanStep.walk)
            const Center(child: _Crosshair()),

          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  step: step,
                  onReport: _showReport,
                  onClose: () => Navigator.pop(context),
                  onStartOver: step == ScanStep.nearEnd &&
                          _session.currentFace == null
                      ? null
                      : _startOver,
                ),
                if (result == null) _GuidanceBanner(guidance: guidance),
                if (result == null && aimingAtAFace)
                  _AimHint(
                    hasAim: _session.hasAim,
                    aimVisible: _session.aimVisible,
                    onClear: _useMiddleAgain,
                  ),
                const Spacer(),
                if (result == null &&
                    (step == ScanStep.walk || step == ScanStep.farEnd))
                  _ProfileStrip(session: _session),
                if (result == null) ...[
                  _LiveReadout(session: _session),
                  _Controls(
                    step: step,
                    canUseThisEnd: _session.canUseCurrentFace,
                    canMarkFarEnd: _session.canMarkFarEnd,
                    onUseThisEnd: _useThisEnd,
                    onAtOtherEnd: _atOtherEnd,
                    onMarkFarEnd: _markFarEnd,
                  ),
                ],
              ],
            ),
          ),

          if (result != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ResultPanel(
                result: result,
                onContinue: _finish,
                onScanAgain: _startOver,
                onCopyReport: _copyReport,
              ),
            ),

          if (_toast != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 150,
              left: 24,
              right: 24,
              child: _SuccessToast(message: _toast!),
            ),
        ],
      ),
    );
  }
}

// --- Pieces -------------------------------------------------------------

const _panel = Color(0xCC000000);
const _good = Color(0xFF34C759);
const _warning = Color(0xFFFFB020);

/// The outline on the log: white while looking, amber while measuring, green
/// once the readings agree.
const _goodColour = Color(0xFF34C759);
const _measuringColour = Color(0xFFFFB020);

/// Where the user is in the three steps.
class _TopBar extends StatelessWidget {
  final ScanStep step;
  final VoidCallback onClose;
  final VoidCallback onReport;
  final VoidCallback? onStartOver;

  const _TopBar({
    required this.step,
    required this.onClose,
    required this.onReport,
    required this.onStartOver,
  });

  @override
  Widget build(BuildContext context) {
    final current = switch (step) {
      ScanStep.nearEnd => 0,
      ScanStep.walk => 1,
      ScanStep.farEnd => 2,
      ScanStep.finished => 3,
    };

    const labels = ["Cut end", "Walk", "Other end"];

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            tooltip: "Close",
          ),
          Expanded(
            // Press and hold: the scan's report, for whoever is testing it.
            child: GestureDetector(
              onLongPress: onReport,
              child: Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: _StepPill(
                        number: i + 1,
                        label: labels[i],
                        done: i < current,
                        active: i == current,
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onStartOver,
            icon: Icon(
              Icons.refresh,
              color: onStartOver == null ? Colors.white24 : Colors.white,
              size: 28,
            ),
            tooltip: "Start over",
          ),
        ],
      ),
    );
  }
}

class _StepPill extends StatelessWidget {
  final int number;
  final String label;
  final bool done;
  final bool active;

  const _StepPill({
    required this.number,
    required this.label,
    required this.done,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final colour = done ? _good : (active ? Colors.white : Colors.white38);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: active ? Colors.white.withValues(alpha: 0.16) : _panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colour.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          done
              ? const Icon(Icons.check_circle, color: _good, size: 16)
              : Text(
                  "$number",
                  style: TextStyle(
                    color: colour,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colour,
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one thing to do now.
class _GuidanceBanner extends StatelessWidget {
  final ScanGuidance guidance;

  const _GuidanceBanner({required this.guidance});

  @override
  Widget build(BuildContext context) {
    final accent = switch (guidance.tone) {
      GuidanceTone.good => _good,
      GuidanceTone.warning => _warning,
      GuidanceTone.neutral => Colors.white,
    };

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        border: Border(left: BorderSide(color: accent, width: 5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            guidance.headline,
            style: TextStyle(
              color: accent,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          if (guidance.detail != null) ...[
            const SizedBox(height: 4),
            Text(
              guidance.detail!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The ring the user puts on the log end. Fills as the reading settles.
class _FaceReticle extends StatelessWidget {
  final double progress;
  final bool seeingFace;

  const _FaceReticle({required this.progress, required this.seeingFace});

  @override
  Widget build(BuildContext context) {
    final colour = seeingFace ? _good : Colors.white;

    return IgnorePointer(
      child: SizedBox(
        width: 170,
        height: 170,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: seeingFace ? progress.clamp(0.0, 1.0) : 0,
                strokeWidth: 7,
                backgroundColor: Colors.white.withValues(alpha: 0.35),
                valueColor: AlwaysStoppedAnimation<Color>(colour),
              ),
            ),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: colour,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black54, width: 2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Icon(Icons.add, color: Colors.white, size: 56),
    );
  }
}

/// The numbers, large, while they are being measured.
class _LiveReadout extends StatelessWidget {
  final LogScanSession session;

  const _LiveReadout({required this.session});

  @override
  Widget build(BuildContext context) {
    final step = session.step;
    final rows = <Widget>[];

    final near = session.nearFace;
    if (near != null) {
      rows.add(
        _SmallFigure(
          label: "Girth, first end",
          value: UnitDisplay.across(
            MeasurementUnits.metresToInches(near.girthMetres),
          ),
          done: true,
        ),
      );
    }

    final face = session.currentFace;

    if (step == ScanStep.nearEnd || step == ScanStep.farEnd) {
      rows.add(
        _BigFigure(
          label: "Girth",
          value: face == null
              ? "—"
              : "${MeasurementUnits.metresToInches(face.girthMetres).toStringAsFixed(1)} in",
          secondary: face == null
              ? null
              : "${(face.girthMetres * 100).toStringAsFixed(1)} cm",
        ),
      );
    }

    if (step == ScanStep.walk) {
      final thinnest = session.liveMinimumGirth;

      if (thinnest != null) {
        rows.add(
          _SmallFigure(
            label: "Thinnest so far",
            value: UnitDisplay.across(
              MeasurementUnits.metresToInches(thinnest.girthMetres),
            ),
            done: false,
          ),
        );
      }
    }

    if (step == ScanStep.walk || step == ScanStep.farEnd) {
      final along = session.furthestAlongMetres;

      rows.add(
        _BigFigure(
          label: "Length so far",
          value: along <= 0
              ? "—"
              : UnitDisplay.feetAndInches(
                  MeasurementUnits.metresToFeet(along),
                ),
          secondary: along <= 0 ? null : "${along.toStringAsFixed(2)} m",
        ),
      );
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

class _BigFigure extends StatelessWidget {
  final String label;
  final String value;
  final String? secondary;

  const _BigFigure({required this.label, required this.value, this.secondary});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const Spacer(),
          Flexible(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
            ),
          ),
          if (secondary != null) ...[
            const SizedBox(width: 8),
            Text(
              secondary!,
              style: const TextStyle(color: Colors.white60, fontSize: 15),
            ),
          ],
        ],
      ),
    );
  }
}

class _SmallFigure extends StatelessWidget {
  final String label;
  final String value;
  final bool done;

  const _SmallFigure({
    required this.label,
    required this.value,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          if (done) const Icon(Icons.check_circle, color: _good, size: 18),
          if (done) const SizedBox(width: 6),
          // Both sides give way rather than overflow: a large accessibility
          // text size, or a long figure, must shrink and not run off the panel.
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The buttons -- only ever the ones that make sense right now.
class _Controls extends StatelessWidget {
  final ScanStep step;
  final bool canUseThisEnd;
  final bool canMarkFarEnd;
  final VoidCallback onUseThisEnd;
  final VoidCallback onAtOtherEnd;
  final VoidCallback onMarkFarEnd;

  const _Controls({
    required this.step,
    required this.canUseThisEnd,
    required this.canMarkFarEnd,
    required this.onUseThisEnd,
    required this.onAtOtherEnd,
    required this.onMarkFarEnd,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    switch (step) {
      case ScanStep.nearEnd:
        children.add(
          _WideButton(
            label: "Use this end",
            icon: Icons.check,
            onPressed: canUseThisEnd ? onUseThisEnd : null,
            primary: false,
          ),
        );

      case ScanStep.walk:
        children.add(
          _WideButton(
            label: "I'm at the other end",
            icon: Icons.flag,
            onPressed: onAtOtherEnd,
            primary: true,
          ),
        );

      case ScanStep.farEnd:
        children.add(
          _WideButton(
            label: "Use this end",
            icon: Icons.check,
            onPressed: canUseThisEnd ? onUseThisEnd : null,
            primary: false,
          ),
        );
        children.add(
          TextButton(
            onPressed: canMarkFarEnd ? onMarkFarEnd : null,
            child: Text(
              "Can't scan this end? End the length here",
              style: TextStyle(
                color: canMarkFarEnd ? Colors.white : Colors.white38,
                fontSize: 15,
                decoration: TextDecoration.underline,
                decorationColor: Colors.white54,
              ),
            ),
          ),
        );

      case ScanStep.finished:
        break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _WideButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  const _WideButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final style = ElevatedButton.styleFrom(
      minimumSize: const Size.fromHeight(58),
      backgroundColor: primary ? _good : Colors.white,
      foregroundColor: Colors.black,
      disabledBackgroundColor: Colors.white24,
      disabledForegroundColor: Colors.white38,
      textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );

    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: style,
    );
  }
}

class _SuccessToast extends StatelessWidget {
  final String message;

  const _SuccessToast({required this.message});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: _good,
            borderRadius: BorderRadius.circular(40),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 12),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 30),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything measured, and the volume it comes to.
class _ResultPanel extends StatelessWidget {
  final LogScanResult result;
  final VoidCallback onContinue;
  final VoidCallback onScanAgain;
  final VoidCallback onCopyReport;

  const _ResultPanel({
    required this.result,
    required this.onContinue,
    required this.onScanAgain,
    required this.onCopyReport,
  });

  @override
  Widget build(BuildContext context) {
    final measurement = result.toMeasurement();
    final prefs = UserPreferencesService.instance.current;

    final volume = volumeForLog(
      prefs: prefs,
      measuredGirthInches: measurement.minGirthInches,
      lengthFeet: measurement.lengthFeet,
    );

    final far = measurement.farFaceGirthInches;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.check_circle, color: _good, size: 30),
                  SizedBox(width: 10),
                  Text(
                    "Log measured",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _ResultRow(
                label: "Girth, first end",
                value: UnitDisplay.across(measurement.faceGirthInches ?? 0),
              ),
              _ResultRow(
                label: "Girth, other end",
                value: far == null ? "Not scanned" : UnitDisplay.across(far),
                muted: far == null,
              ),
              _ResultRow(
                label: "Thinnest girth",
                note: measurement.minGirthWhere,
                value: UnitDisplay.across(measurement.minGirthInches),
                emphasised: true,
              ),
              _ResultRow(
                label: result.lengthEstimated
                    ? "Length (estimated)"
                    : "Length, end to end",
                value: UnitDisplay.length(measurement.lengthFeet),
                emphasised: true,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 64,
                child: CustomPaint(
                  painter: _ProfilePainter(
                    points: result.profile,
                    reference: result.faceGirthMetres,
                    lengthMetres: math.max(result.lengthMetres, 0.5),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const Divider(color: Colors.white24, height: 22),
              _ResultRow(
                label: "Volume",
                value: UnitDisplay.volume(volume.cubicFeetDecimal),
                note: prefs.volumeMethod == VolumeMethod.referenceTable
                    ? UnitDisplay.adiAngal(volume.adi, volume.angal)
                    : null,
                emphasised: true,
              ),
              if (measurement.limitingFactorMessage != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    measurement.limitingFactorMessage!,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _WideButton(
                label: "Continue",
                icon: Icons.arrow_forward,
                onPressed: onContinue,
                primary: true,
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: onScanAgain,
                child: const Text(
                  "Scan again",
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              TextButton(
                onPressed: onCopyReport,
                child: const Text(
                  "Copy scan report",
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final bool emphasised;
  final bool muted;

  const _ResultRow({
    required this.label,
    required this.value,
    this.note,
    this.emphasised = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: emphasised ? 16 : 15,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: muted ? Colors.white38 : Colors.white,
                fontSize: emphasised ? 18 : 15,
                fontWeight: emphasised ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one line that says how to choose an end, and undoes the choice.
class _AimHint extends StatelessWidget {
  final bool hasAim;
  final bool aimVisible;
  final VoidCallback onClear;

  const _AimHint({
    required this.hasAim,
    required this.aimVisible,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final text = !hasAim
        ? "Tap the end you want to measure"
        : (aimVisible
            ? "Measuring the end you tapped"
            : "The end you tapped is out of view — point back at it");

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: hasAim && !aimVisible ? _warning : Colors.white70,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          if (hasAim) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onClear,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  "Use the middle",
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The girth along the log as it is read, drawn while the user walks: the
/// proof that the trunk is being measured, and the place a waist shows up.
class _ProfileStrip extends StatelessWidget {
  final LogScanSession session;

  const _ProfileStrip({required this.session});

  @override
  Widget build(BuildContext context) {
    final near = session.nearFace;
    if (near == null) return const SizedBox.shrink();

    final points = session.liveProfile;

    return Container(
      height: 58,
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: CustomPaint(
        painter: _ProfilePainter(
          points: points,
          reference: near.girthMetres,
          lengthMetres: math.max(session.furthestAlongMetres, 0.5),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Girth against distance along the log, with the first end's girth as a
/// dashed reference line.
class _ProfilePainter extends CustomPainter {
  final List<GirthAtPosition> points;
  final double reference;
  final double lengthMetres;

  const _ProfilePainter({
    required this.points,
    required this.reference,
    required this.lengthMetres,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (reference <= 0 || size.width <= 0 || size.height <= 0) return;

    const pad = 8.0;

    // Room for a log 25% thinner or 15% fatter than the end it started at.
    final low = reference * 0.75;
    final high = reference * 1.15;

    double xFor(double along) =>
        pad + (size.width - 2 * pad) * (along / lengthMetres).clamp(0.0, 1.0);

    double yFor(double girth) =>
        pad +
        (size.height - 2 * pad) *
            (1 - ((girth - low) / (high - low)).clamp(0.0, 1.0));

    final guide = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    final y = yFor(reference);
    for (var x = pad; x < size.width - pad; x += 8) {
      canvas.drawLine(Offset(x, y), Offset(x + 4, y), guide);
    }

    if (points.length < 2) return;

    final line = Paint()
      ..color = _good
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();

    for (var i = 0; i < points.length; i++) {
      final p = Offset(xFor(points[i].axialPosition), yFor(points[i].girthMetres));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }

    canvas.drawPath(path, line);

    // The thinnest place, marked.
    var thinnest = points.first;
    for (final p in points) {
      if (p.girthMetres < thinnest.girthMetres) thinnest = p;
    }

    canvas.drawCircle(
      Offset(xFor(thinnest.axialPosition), yFor(thinnest.girthMetres)),
      4.5,
      Paint()..color = _warning,
    );
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.points != points ||
      old.reference != reference ||
      old.lengthMetres != lengthMetres;
}
