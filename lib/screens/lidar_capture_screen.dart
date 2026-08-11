import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/lidar_scanner_service.dart';
import '../utils/scan_coverage.dart';

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

class _LidarCaptureScreenState extends State<LidarCaptureScreen> {
  int? _viewId;
  _Stage _stage = _Stage.aiming;

  ScanProgress _progress = const ScanProgress();

  ScanCoverage get _coverage => ScanCoverage(_progress);

  String? _error;
  String? _hint;
  bool _capturing = false;

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
        });

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

    setState(() => _progress = ScanProgress.fromNative(arguments));
  }

  /// Whether a measurement taken now would be worth trusting.
  ///
  /// Nothing finishes the sweep on the user's behalf any more. It used to
  /// end itself once the bounding box stopped growing for 1.6 seconds,
  /// which meant pausing to reposition -- or circling the girth before
  /// walking the length -- ended the measurement early and silently, with a
  /// whole end of the log never looked at.
  bool get _hasEnoughToMeasure => _coverage.isReady;

  /// How far along the sweep is, for the progress ring.
  double get _completion => _stage == _Stage.aiming ? 0 : _coverage.completion;

  Future<void> _redo() async {
    final id = _viewId;
    if (id == null) return;

    await LidarScannerService.instance.clearTaps(id);
    if (!mounted) return;

    setState(() {
      _stage = _Stage.aiming;
      _progress = const ScanProgress();
      _hint = null;
      _error = null;
    });
  }

  Future<void> _capture() async {
    final id = _viewId;
    if (id == null || _capturing) return;

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
      // The coverage model decides what to ask for next, so the headline
      // always names the one thing standing between the user and a
      // trustworthy measurement.
      _Stage.sweeping => _coverage.message,
      _Stage.finishing => "Measuring…",
    };
  }

  String get _subtitle {
    return switch (_stage) {
      _Stage.aiming =>
        "Stand 0.7–1.5 m away. The app separates the log from the ground "
            "and from the logs beside it.",
      _Stage.sweeping =>
        "The green sleeve is the log being measured. Both end discs turn "
            "green once that end has actually been seen.",
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

          // What is still outstanding. A disabled Finish button with no
          // explanation is the most frustrating thing an app can do, so
          // every requirement is on screen with its current state.
          if (_stage == _Stage.sweeping)
            Positioned(
              left: 16,
              right: 16,
              bottom: 110,
              child: _CoverageChecklist(coverage: _coverage),
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
                        onPressed: _stage == _Stage.aiming || _capturing
                            ? null
                            : _redo,
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
                        // Only once the log has actually been seen: both cut
                        // ends and enough of the way round. Nothing finishes
                        // on the user's behalf, and nothing lets them finish
                        // a sweep that would produce a volume worth less
                        // than the paper it gets printed on. The banner
                        // above says which requirement is outstanding.
                        onPressed: (_stage == _Stage.sweeping &&
                                !_capturing &&
                                _hasEnoughToMeasure)
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
                          _hasEnoughToMeasure ? "Finish" : "Keep scanning",
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

/// The requirements a sweep has to meet, and which are outstanding.
///
/// Shown while sweeping because the Finish button is disabled until the log
/// has actually been seen, and a disabled button without a reason is worse
/// than no button at all.
class _CoverageChecklist extends StatelessWidget {
  final ScanCoverage coverage;

  const _CoverageChecklist({required this.coverage});

  @override
  Widget build(BuildContext context) {
    final items = coverage.checklist;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    item.done
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 15,
                    color: item.done ? Colors.greenAccent : Colors.white54,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: item.done ? Colors.white : Colors.white70,
                        fontWeight:
                            item.done ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  Text(
                    item.detail,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white60,
                      fontFamily: "monospace",
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
