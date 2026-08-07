import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/cutting_models.dart';
import '../services/cutting_engine.dart';
import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../services/lidar_service.dart';
import '../services/user_preferences_service.dart';
import '../widgets/cutting_setup_sheet.dart';
import 'cutting_result_screen.dart';
import 'lidar_measurement_screen.dart';
import 'log_face_trace_screen.dart';

enum _Stage {
  modeSelect,
  manualCamera,
}

class OptimalCuttingScreen extends StatefulWidget {
  const OptimalCuttingScreen({super.key});

  @override
  State<OptimalCuttingScreen> createState() => _OptimalCuttingScreenState();
}

class _OptimalCuttingScreenState extends State<OptimalCuttingScreen> {
  _Stage _stage = _Stage.modeSelect;

  bool _checkingLiDAR = true;
  bool _lidarAvailable = false;

  CameraController? _cameraController;
  bool _cameraLoading = true;
  bool _cameraReady = false;
  bool _imageCaptured = false;
  XFile? _capturedImage;

  /// The traced face, in inches, once the user has outlined the photo.
  ///
  /// Null means "no photo, or not traced yet", and the engine falls back to a
  /// circle of the measured diameter -- the behaviour before any of this.
  LogFaceOutline? _outline;

  /// Flaws marked on that face. Only consulted when the profile's
  /// "Consider defects" switch is on.
  List<LogDefect> _defects = const [];

  /// The tape reading that gave the outline its scale, carried forward so
  /// the setup sheet can show the real measured diameter instead of a guess.
  double? _tracedGirthInches;

  @override
  void initState() {
    super.initState();
    _checkLiDAR();
  }

  Future<void> _checkLiDAR() async {
    // Feature-point AR, not depth scanning -- this flow works on any
    // ARKit-capable iPhone, so it deliberately uses the broader check.
    final available = await LiDARService.instance.isARAvailable();
    if (!mounted) return;
    setState(() {
      _lidarAvailable = available;
      _checkingLiDAR = false;
    });
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

  Future<void> _captureImage() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    final image = await _cameraController!.takePicture();

    if (!mounted) return;

    setState(() {
      _capturedImage = image;
      _imageCaptured = true;
    });
  }

  void _retake() {
    setState(() {
      _imageCaptured = false;
      _capturedImage = null;
      // The outline belongs to the photo that was just discarded; keeping it
      // would pack boards into the shape of a different log.
      _outline = null;
      _defects = const [];
      _tracedGirthInches = null;
    });
  }

  /// Opens the tracing screen for the captured photo.
  ///
  /// This is what makes the photo count. Before it, the picture was only
  /// ever attached to the PDF -- the engine packed into a circle no matter
  /// what the log actually looked like.
  Future<void> _traceFace(File photo) async {
    final traced = await Navigator.push<LogFaceTraceResult?>(
      context,
      MaterialPageRoute(
        builder: (_) => LogFaceTraceScreen(
          photo: photo,
          initialGirthInches: _tracedGirthInches,
        ),
      ),
    );

    if (!mounted || traced == null) return;

    // The tracing screen speaks inches, because that is what the tape reads.
    // Everything downstream of the setup sheet -- board width, blade kerf,
    // log diameter -- is in millimetres. Converting here, at the one border
    // between the two, keeps a 150mm board from ever being measured against
    // a 20-unit log.
    const mmPerInch = 25.4;

    setState(() {
      _outline = traced.outline.scaled(mmPerInch);
      _defects = [for (final d in traced.defects) d.scaled(mmPerInch)];
      _tracedGirthInches = traced.girthInches;
    });

    await _proceedManual(photo: photo);
  }

  Future<void> _openLiDARFlow() async {
    if (!_lidarAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "LiDAR scanning isn't available on this device. Use Manual Measurements instead.",
          ),
        ),
      );
      return;
    }

    final result = await Navigator.push<LiDARMeasurementResult?>(
      context,
      MaterialPageRoute(builder: (_) => const LiDARMeasurementScreen()),
    );

    if (!mounted) return;

    if (result == null) {
      // User chose "Switch to Manual" inside the LiDAR screen.
      setState(() => _stage = _Stage.manualCamera);
      _initCamera();
      return;
    }

    final input = await showCuttingSetupSheet(
      context,
      logDimensions: result.logDimensions,
      measuredViaLidar: true,
    );

    if (input == null || !mounted) return;

    final cuttingResult = CuttingEngine.generate(
      input,
      outline: _outline,
      defects: _defects,
      avoidDefects: UserPreferencesService.instance.current.avoidDefects,
    );

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CuttingResultScreen(
          imageFile: result.photo,
          input: input,
          result: cuttingResult,
        ),
      ),
    );
  }

  void _openManualFlow() {
    setState(() => _stage = _Stage.manualCamera);
    _initCamera();
  }

  Future<void> _proceedManual({File? photo}) async {
    final traced = _outline;

    // Pre-fill from the trace so the sheet cannot show a diameter that
    // contradicts the shape the user just outlined. Still editable: only a
    // LiDAR reading locks the field.
    final input = await showCuttingSetupSheet(
      context,
      logDimensions: traced == null
          ? null
          : CuttingInput(
              logDiameter: traced.equivalentCircleDiameter,
              logLength: 3000,
              boardWidth: 150,
              boardHeight: 50,
              bladeThickness: 3,
              boardPrice: 250,
            ),
    );

    if (input == null || !mounted) return;

    final cuttingResult = CuttingEngine.generate(
      input,
      outline: _outline,
      defects: _defects,
      avoidDefects: UserPreferencesService.instance.current.avoidDefects,
    );

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CuttingResultScreen(
          imageFile: photo,
          input: input,
          result: cuttingResult,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffF5F7FA),
      appBar: AppBar(
        centerTitle: true,
        title: const Text("Optimal Cutting"),
      ),
      body: SafeArea(
        child: _stage == _Stage.modeSelect
            ? _buildModeSelect()
            : _buildManualCamera(),
      ),
    );
  }

  Widget _buildModeSelect() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 10),
          const Text(
            "How would you like to measure the log?",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            "A photo of the log is required for LiDAR scanning. For manual entry, taking a photo is recommended but optional.",
            style: TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 30),
          _modeCard(
            title: "Scan with LiDAR",
            subtitle: _checkingLiDAR
                ? "Checking device support..."
                : (_lidarAvailable
                    ? "Automatically measure diameter and length using your iPhone's LiDAR sensor."
                    : "Not available on this device."),
            icon: Icons.sensors,
            enabled: !_checkingLiDAR,
            highlighted: _lidarAvailable,
            onTap: _openLiDARFlow,
          ),
          const SizedBox(height: 20),
          _modeCard(
            title: "Manual Measurements",
            subtitle:
                "Enter the log's diameter and length yourself, with an optional photo.",
            icon: Icons.rule,
            enabled: true,
            highlighted: true,
            onTap: _openManualFlow,
          ),
        ],
      ),
    );
  }

  Widget _modeCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool enabled,
    required bool highlighted,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? onTap : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: highlighted ? Colors.green : Colors.grey.shade300,
              width: highlighted ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Colors.green.withValues(alpha: 0.12),
                child: Icon(icon, color: Colors.green, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualCamera() {
    Widget cameraPreview;

    if (_cameraLoading) {
      cameraPreview = const Center(child: CircularProgressIndicator());
    } else if (!_cameraReady) {
      cameraPreview = const Center(
        child: Text(
          "Camera not available",
          style: TextStyle(color: Colors.white),
        ),
      );
    } else if (_imageCaptured) {
      cameraPreview = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.file(File(_capturedImage!.path), fit: BoxFit.cover),
      );
    } else {
      cameraPreview = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: CameraPreview(_cameraController!),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          const SizedBox(height: 15),
          const Text(
            "Photograph the Log (Optional)",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _imageCaptured
                ? "Image captured successfully."
                : "Align the timber log inside the guide, or skip below.",
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 320,
              height: 320,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: cameraPreview,
                  ),
                  if (!_imageCaptured)
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
          const SizedBox(height: 25),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _imageCaptured
                ? Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _retake,
                          icon: const Icon(Icons.refresh),
                          label: const Text("Retake"),
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _traceFace(
                            File(_capturedImage!.path),
                          ),
                          icon: const Icon(Icons.gesture),
                          label: const Text("Trace Face"),
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton.icon(
                      onPressed: _cameraReady ? _captureImage : null,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text("Capture Log Surface"),
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          if (!_imageCaptured)
            TextButton(
              onPressed: () => _proceedManual(),
              child: const Text("Skip photo, enter manually"),
            ),
        ],
      ),
    );
  }
}
