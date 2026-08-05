import 'dart:io';

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../models/cutting_models.dart';
import '../utils/log_edge_detector.dart';

/// Result of a completed LiDAR scan: the photo taken and a [CuttingInput]
/// with only the log dimensions filled in (board/blade/price are left at 0
/// for the caller to collect next in the setup sheet).
class LiDARMeasurementResult {
  final File photo;
  final CuttingInput logDimensions;

  const LiDARMeasurementResult({
    required this.photo,
    required this.logDimensions,
  });
}

enum _Phase {
  photo,
  detecting,
  confirmBoundary,
  arDiameter,
  arLength,
  review,
}

class LiDARMeasurementScreen extends StatefulWidget {
  const LiDARMeasurementScreen({super.key});

  @override
  State<LiDARMeasurementScreen> createState() => _LiDARMeasurementScreenState();
}

class _LiDARMeasurementScreenState extends State<LiDARMeasurementScreen> {
  CameraController? _cameraController;
  bool _cameraLoading = true;
  bool _cameraReady = false;

  File? _photo;
  LogBoundary? _boundary;

  _Phase _phase = _Phase.photo;

  ARKitController? _arkitController;
  vector.Vector3? _pointA;
  vector.Vector3? _pointB;

  double? _diameterMeters;
  double? _lengthMeters;

  final List<String> _placedNodeNames = [];

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _cameraLoading = false);
        return;
      }

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (!mounted) return;

      setState(() {
        _cameraLoading = false;
        _cameraReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraReady = false;
      });
    }
  }

  Future<void> _capture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    final image = await _cameraController!.takePicture();
    final file = File(image.path);

    if (!mounted) return;

    setState(() {
      _photo = file;
      _phase = _Phase.detecting;
    });

    final boundary = await LogEdgeDetector.detect(file);

    if (!mounted) return;

    setState(() {
      _boundary = boundary;
      _phase = _Phase.confirmBoundary;
    });
  }

  void _onARKitViewCreated(ARKitController controller) {
    _arkitController = controller;
    controller.onARTap = _handleARTap;
  }

  void _handleARTap(List<ARKitTestResult> results) {
    final point = results.firstWhereOrNull(
      (o) => o.type == ARKitHitTestResultType.featurePoint,
    );

    if (point == null) return;

    final column = point.worldTransform.getColumn(3);
    final position = vector.Vector3(column.x, column.y, column.z);

    final material = ARKitMaterial(
      lightingModelName: ARKitLightingModel.constant,
      diffuse: ARKitMaterialProperty.color(Colors.greenAccent),
    );

    final sphere = ARKitSphere(radius: 0.006, materials: [material]);

    final nodeName = "marker_${_placedNodeNames.length}";

    _arkitController!.add(
      ARKitNode(geometry: sphere, position: position, name: nodeName),
    );

    _placedNodeNames.add(nodeName);

    setState(() {
      if (_pointA == null) {
        _pointA = position;
        return;
      }

      if (_pointB == null) {
        _pointB = position;

        _arkitController!.add(
          ARKitNode(
            geometry: ARKitLine(fromVector: _pointA!, toVector: _pointB!),
          ),
        );

        final distance = _pointA!.distanceTo(_pointB!);

        if (_phase == _Phase.arDiameter) {
          _diameterMeters = distance;
        } else if (_phase == _Phase.arLength) {
          _lengthMeters = distance;
        }
      }
    });
  }

  void _clearMarkers() {
    for (final name in _placedNodeNames) {
      _arkitController?.remove(name).catchError((_) {});
    }
    _placedNodeNames.clear();
  }

  void _redoMeasurement() {
    _clearMarkers();
    setState(() {
      _pointA = null;
      _pointB = null;
      if (_phase == _Phase.arDiameter) _diameterMeters = null;
      if (_phase == _Phase.arLength) _lengthMeters = null;
    });
  }

  void _confirmMeasurement() {
    _clearMarkers();
    setState(() {
      _pointA = null;
      _pointB = null;

      if (_phase == _Phase.arDiameter) {
        _phase = _Phase.arLength;
      } else if (_phase == _Phase.arLength) {
        _phase = _Phase.review;
      }
    });
  }

  void _finish() {
    if (_diameterMeters == null || _lengthMeters == null || _photo == null) {
      return;
    }

    Navigator.pop(
      context,
      LiDARMeasurementResult(
        photo: _photo!,
        logDimensions: CuttingInput(
          logDiameter: _diameterMeters! * 1000,
          logLength: _lengthMeters! * 1000,
          boardWidth: 0,
          boardHeight: 0,
          bladeThickness: 0,
          boardPrice: 0,
        ),
      ),
    );
  }

  void _switchToManual() {
    Navigator.pop(context, null);
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _arkitController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("LiDAR Log Scan"),
        actions: [
          TextButton(
            onPressed: _switchToManual,
            child: const Text(
              "Switch to Manual",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.photo:
        return _buildPhotoStep();
      case _Phase.detecting:
        return const Center(
          child: CircularProgressIndicator(color: Colors.green),
        );
      case _Phase.confirmBoundary:
        return _buildBoundaryConfirm();
      case _Phase.arDiameter:
        return _buildArStep(
          title: "Measure Diameter",
          instructions: "Tap the two opposite edges of the log's cut face.",
        );
      case _Phase.arLength:
        return _buildArStep(
          title: "Measure Length",
          instructions: "Tap both ends of the log along its length.",
        );
      case _Phase.review:
        return _buildReview();
    }
  }

  Widget _buildPhotoStep() {
    Widget cameraPreview;

    if (_cameraLoading) {
      cameraPreview = const Center(
        child: CircularProgressIndicator(color: Colors.green),
      );
    } else if (!_cameraReady) {
      cameraPreview = const Center(
        child: Text(
          "Camera not available",
          style: TextStyle(color: Colors.white),
        ),
      );
    } else {
      cameraPreview = CameraPreview(_cameraController!);
    }

    return Column(
      children: [
        const SizedBox(height: 15),
        const Text(
          "Photograph the Log",
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 30),
          child: Text(
            "A photo is required before scanning. Align the log's cut face inside the guide.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: Center(
            child: SizedBox(
              width: 320,
              height: 320,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: SizedBox(
                      width: 300,
                      height: 300,
                      child: cameraPreview,
                    ),
                  ),
                  IgnorePointer(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.green, width: 4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: 260,
            height: 55,
            child: ElevatedButton.icon(
              onPressed: _cameraReady ? _capture : null,
              icon: const Icon(Icons.camera_alt),
              label: const Text("Capture Log Surface"),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBoundaryConfirm() {
    return Column(
      children: [
        const SizedBox(height: 15),
        const Text(
          "Log Detected",
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Text(
            _boundary != null
                ? "Basic image recognition outlined the log below for your confirmation."
                : "Could not auto-outline the log — that's fine, continue to measure it with LiDAR.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(_photo!, fit: BoxFit.cover),
                      if (_boundary != null)
                        CustomPaint(
                          painter: _BoundaryPainter(_boundary!),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: 280,
            height: 55,
            child: ElevatedButton.icon(
              onPressed: () => setState(() => _phase = _Phase.arDiameter),
              icon: const Icon(Icons.sensors),
              label: const Text("Continue to LiDAR Scan"),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArStep({
    required String title,
    required String instructions,
  }) {
    final bool hasAny = _pointA != null || _pointB != null;
    final bool hasBoth = _pointA != null && _pointB != null;

    double? liveDistance;
    if (hasBoth) {
      liveDistance = _pointA!.distanceTo(_pointB!);
    }

    return Stack(
      children: [
        ARKitSceneView(
          enableTapRecognizer: true,
          onARKitViewCreated: _onARKitViewCreated,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.all(16),
            color: Colors.black54,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  instructions,
                  style: const TextStyle(color: Colors.white70),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (liveDistance != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      "${(liveDistance * 100).toStringAsFixed(1)} cm",
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _pointA == null
                          ? "Tap the first point"
                          : "Tap the second point",
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: hasAny ? _redoMeasurement : null,
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
                        onPressed: hasBoth ? _confirmMeasurement : null,
                        icon: const Icon(Icons.check_circle),
                        label: const Text("Confirm"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReview() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle, size: 80, color: Colors.green),
        const SizedBox(height: 20),
        const Text(
          "Measurements Captured",
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 20),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 30),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _reviewRow(
                  "Diameter",
                  "${(_diameterMeters! * 1000).toStringAsFixed(0)} mm",
                ),
                const Divider(),
                _reviewRow(
                  "Length",
                  "${(_lengthMeters! * 1000).toStringAsFixed(0)} mm",
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 30),
        SizedBox(
          width: 260,
          height: 55,
          child: ElevatedButton.icon(
            onPressed: _finish,
            icon: const Icon(Icons.arrow_forward),
            label: const Text("Continue"),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () {
            setState(() {
              _diameterMeters = null;
              _lengthMeters = null;
              _phase = _Phase.arDiameter;
            });
          },
          child: const Text(
            "Measure Again",
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ],
    );
  }

  Widget _reviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _BoundaryPainter extends CustomPainter {
  final LogBoundary boundary;

  _BoundaryPainter(this.boundary);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      boundary.leftFraction * size.width,
      boundary.topFraction * size.height,
      boundary.rightFraction * size.width,
      boundary.bottomFraction * size.height,
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.greenAccent;

    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _BoundaryPainter oldDelegate) {
    return oldDelegate.boundary != boundary;
  }
}
