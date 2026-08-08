import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/lidar_scanner_service.dart';

/// Hosts the native AR view and guides one continuous sweep of a log.
///
/// The flow is deliberately two beats long: tap the log, then walk its
/// length. Everything else -- separating the log from the ground, finding
/// its axis, deciding when enough has been gathered -- is the app's job.
///
/// Returns a [PointCloudCapture] via `Navigator.pop`, or null if the user
/// backed out or the session failed. All geometry happens afterwards in
/// Dart; this screen only collects points.
class LidarCaptureScreen extends StatefulWidget {
  const LidarCaptureScreen({super.key});

  @override
  State<LidarCaptureScreen> createState() => _LidarCaptureScreenState();
}

enum _Stage { aiming, sweeping, finishing }

/// Live progress reported by the native accumulator.
class _SweepProgress {
  final int pointCount;
  final double extentMetres;

  const _SweepProgress({this.pointCount = 0, this.extentMetres = 0});
}

class _LidarCaptureScreenState extends State<LidarCaptureScreen> {
  /// Enough surface to fit circles along a log with confidence. Below this
  /// the sweep is still usable but the quality gate will likely refuse it.
  static const int _targetPointCount = 12000;

  /// A log shorter than this is almost certainly a mis-tap on something
  /// else, so the sweep is not considered complete until it is exceeded.
  static const double _minPlausibleLengthMetres = 0.5;

  /// The sweep finishes on its own once coverage stops growing for this
  /// long. Waiting for the user to decide they are done is one more thing
  /// to explain and one more tap to make.
  static const Duration _plateauBeforeFinish = Duration(milliseconds: 1600);

  /// Growth below this between updates counts as "not growing".
  static const double _plateauToleranceMetres = 0.02;

  int? _viewId;
  _Stage _stage = _Stage.aiming;

  _SweepProgress _progress = const _SweepProgress();

  String? _error;
  String? _hint;
  bool _capturing = false;

  double _bestExtent = 0;
  DateTime? _lastGrowth;
  Timer? _plateauTimer;

  @override
  void dispose() {
    _plateauTimer?.cancel();
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    // Listen on the per-view channel so native taps, progress and session
    // failures reach the UI.
    MethodChannel("smartlog/lidar_scanner/view_$id")
        .setMethodCallHandler(_handleNativeCall);

    setState(() => _viewId = id);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (!mounted) return null;

    switch (call.method) {
      case "tapped":
        setState(() {
          _stage = _Stage.sweeping;
          _hint = null;
          _error = null;
          _bestExtent = 0;
          _lastGrowth = DateTime.now();
        });
        _startPlateauWatch();

      case "progress":
        _onProgress(call.arguments);

      case "tapMissed":
        final args = call.arguments;
        setState(() {
          _hint = args is Map ? args["message"] as String? : null;
        });

      case "sessionFailed":
        final args = call.arguments;
        setState(() {
          _error = args is Map
              ? (args["message"] as String? ?? "The camera session failed.")
              : "The camera session failed.";
        });

      case "sessionInterrupted":
        setState(() => _hint = "Camera interrupted — hold still.");

      case "sessionResumed":
        setState(() => _hint = null);
    }

    return null;
  }

  void _onProgress(Object? arguments) {
    if (arguments is! Map) return;

    final points = arguments["pointCount"];
    final extent = arguments["extent"];

    final progress = _SweepProgress(
      pointCount: points is num ? points.toInt() : 0,
      extentMetres: extent is num ? extent.toDouble() : 0,
    );

    if (progress.extentMetres > _bestExtent + _plateauToleranceMetres) {
      _bestExtent = progress.extentMetres;
      _lastGrowth = DateTime.now();
    }

    setState(() => _progress = progress);
  }

  /// Watches for the sweep to stop improving, then finishes it.
  void _startPlateauWatch() {
    _plateauTimer?.cancel();

    _plateauTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) {
        if (!mounted || _stage != _Stage.sweeping) return;
        if (!_hasEnoughToMeasure) return;

        final since = _lastGrowth;
        if (since == null) return;

        if (DateTime.now().difference(since) >= _plateauBeforeFinish) {
          _capture();
        }
      },
    );
  }

  bool get _hasEnoughToMeasure =>
      _progress.pointCount >= _targetPointCount &&
      _bestExtent >= _minPlausibleLengthMetres;

  /// How far along the sweep is, for the progress ring.
  double get _completion {
    if (_stage == _Stage.aiming) return 0;

    final byPoints = _progress.pointCount / _targetPointCount;
    final byLength = _bestExtent / _minPlausibleLengthMetres;

    final worst = byPoints < byLength ? byPoints : byLength;
    return worst.clamp(0.0, 1.0);
  }

  Future<void> _redo() async {
    final id = _viewId;
    if (id == null) return;

    _plateauTimer?.cancel();
    await LidarScannerService.instance.clearTaps(id);
    if (!mounted) return;

    setState(() {
      _stage = _Stage.aiming;
      _progress = const _SweepProgress();
      _bestExtent = 0;
      _lastGrowth = null;
      _hint = null;
      _error = null;
    });
  }

  Future<void> _capture() async {
    final id = _viewId;
    if (id == null || _capturing) return;

    _plateauTimer?.cancel();

    setState(() {
      _capturing = true;
      _stage = _Stage.finishing;
    });

    // Freeze the cloud first: letting it grow while it is being read would
    // measure something slightly different from what was on screen.
    await LidarScannerService.instance.stopSweep(id);

    final capture = await LidarScannerService.instance.capture(id);

    if (!mounted) return;

    if (capture == null) {
      setState(() {
        _capturing = false;
        _stage = _Stage.sweeping;
        _error = "Could not read depth data. Move closer to the log, "
            "avoid direct sunlight, and try again.";
      });
      return;
    }

    if (capture.taps.isEmpty) {
      setState(() {
        _capturing = false;
        _stage = _Stage.aiming;
        _error = "Tap the log you want to measure first.";
      });
      return;
    }

    Navigator.pop(context, capture);
  }

  String get _headline {
    if (_error != null) return _error!;
    if (_hint != null) return _hint!;

    return switch (_stage) {
      _Stage.aiming => "Tap the log you want to measure.",
      _Stage.sweeping => _hasEnoughToMeasure
          ? "Good. Hold still — finishing."
          : "Now walk slowly along the log.",
      _Stage.finishing => "Measuring…",
    };
  }

  String get _subtitle {
    return switch (_stage) {
      _Stage.aiming =>
        "Stand 0.7–1.5 m away. The app separates the log from the ground "
            "and from the logs beside it.",
      _Stage.sweeping =>
        "Keep it in frame from end to end. The more of its curve the "
            "sensor sees, the tighter the girth.",
      _Stage.finishing => "Working out girth, length and volume.",
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Scan Log"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancel",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Exactly ONE of these. Each instance creates its own ARSession,
          // and a second session pauses the first -- frozen preview, dead
          // capture. This is also why the Optimal Cutting AR screen (which
          // uses arkit_plugin's own session) must never be open at the
          // same time as this one.
          Positioned.fill(
            child: UiKitView(
              viewType: LidarScannerService.platformViewType,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onPlatformViewCreated,
            ),
          ),

          if (_stage == _Stage.aiming) const _AimingReticle(),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _GuidanceBanner(
              headline: _headline,
              subtitle: _subtitle,
              isError: _error != null,
              completion: _completion,
              showProgress: _stage != _Stage.aiming,
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(20),
              color: Colors.black54,
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _stage == _Stage.aiming || _capturing ? null : _redo,
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        label: const Text(
                          "Start over",
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: ElevatedButton.icon(
                        // Always available once a log is chosen: the sweep
                        // finishes itself, but a user who can see they are
                        // done should never have to wait for it.
                        onPressed: (_stage == _Stage.sweeping && !_capturing)
                            ? _capture
                            : null,
                        icon: _capturing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.straighten),
                        label: Text(
                          _hasEnoughToMeasure ? "Done" : "Measure now",
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A crosshair shown while the user is choosing which log to measure.
class _AimingReticle extends StatelessWidget {
  const _AimingReticle();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.greenAccent, width: 2),
            borderRadius: BorderRadius.circular(48),
          ),
          child: const Icon(
            Icons.touch_app,
            color: Colors.greenAccent,
            size: 32,
          ),
        ),
      ),
    );
  }
}

class _GuidanceBanner extends StatelessWidget {
  final String headline;
  final String subtitle;
  final bool isError;
  final double completion;
  final bool showProgress;

  const _GuidanceBanner({
    required this.headline,
    required this.subtitle,
    required this.isError,
    required this.completion,
    required this.showProgress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.black54,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headline,
              style: TextStyle(
                color: isError ? Colors.orangeAccent : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (showProgress) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: completion,
                  minHeight: 6,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Colors.greenAccent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
