import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/lidar_scanner_service.dart';

/// Hosts the native AR view and walks the user through marking a log's two
/// ends, then captures a depth frame.
///
/// Returns a [PointCloudCapture] via `Navigator.pop`, or null if the user
/// backed out or the session failed. All geometry happens afterwards in
/// Dart -- this screen only collects points.
class LidarCaptureScreen extends StatefulWidget {
  const LidarCaptureScreen({super.key});

  @override
  State<LidarCaptureScreen> createState() => _LidarCaptureScreenState();
}

class _LidarCaptureScreenState extends State<LidarCaptureScreen> {
  int? _viewId;

  int _tapCount = 0;
  String? _error;
  String? _hint;
  bool _capturing = false;

  void _onPlatformViewCreated(int id) {
    // Listen on the per-view channel so native taps and session failures
    // reach the UI.
    MethodChannel("smartlog/lidar_scanner/view_$id")
        .setMethodCallHandler(_handleNativeCall);

    setState(() => _viewId = id);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (!mounted) return null;

    switch (call.method) {
      case "tapped":
        setState(() {
          _tapCount += 1;
          _hint = null;
          _error = null;
        });

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

  Future<void> _redoTaps() async {
    final id = _viewId;
    if (id == null) return;

    await LidarScannerService.instance.clearTaps(id);
    if (!mounted) return;

    setState(() {
      _tapCount = 0;
      _hint = null;
    });
  }

  Future<void> _capture() async {
    final id = _viewId;
    if (id == null || _capturing) return;

    setState(() => _capturing = true);

    final capture = await LidarScannerService.instance.capture(id);

    if (!mounted) return;

    setState(() => _capturing = false);

    if (capture == null) {
      setState(() {
        _error = "Could not read depth data. Move closer to the log, "
            "avoid direct sunlight, and try again.";
      });
      return;
    }

    if (capture.taps.length < 2) {
      setState(() {
        _error = "Both ends of the log need to be marked before capturing.";
      });
      return;
    }

    Navigator.pop(context, capture);
  }

  String get _instruction {
    if (_error != null) return _error!;
    if (_hint != null) return _hint!;

    return switch (_tapCount) {
      0 => "Tap one end of the log.",
      1 => "Now tap the other end.",
      _ => "Both ends marked. Stand square to the log, then capture.",
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

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black54,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Step ${_tapCount >= 2 ? 3 : _tapCount + 1} of 3",
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _instruction,
                    style: TextStyle(
                      color: _error != null
                          ? Colors.orangeAccent
                          : Colors.white,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "Stand 0.7–1.5 m away, square to the log. Avoid direct "
                    "sunlight — it swamps the depth sensor.",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
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
                        onPressed: _tapCount > 0 ? _redoTaps : null,
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        label: const Text(
                          "Redo",
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed:
                            (_tapCount >= 2 && !_capturing) ? _capture : null,
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
                        label: const Text("Measure"),
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
