import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../services/lidar_service.dart';
import '../services/sawing_engine.dart';
import '../services/user_preferences_service.dart';
import '../widgets/cutting_setup_sheet.dart';
import '../widgets/image_source_sheet.dart';
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

  /// Where the traced face sits on the photograph, so the finished plan can
  /// be drawn back onto the log the user is looking at.
  PatternOverlay? _overlay;

  /// Filled in by the LiDAR flow, which measures the length the photo cannot.
  double? _measuredLengthMm;

  /// True while the engine is searching. It tries every rotation and offset
  /// against a rasterised face, which is half a second on a desktop and
  /// several times that on a phone -- long enough that it must not run on
  /// the thread painting the screen.
  bool _planning = false;

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

  /// Takes a photo the user already has and goes straight to tracing.
  Future<void> _chooseFromGallery() async {
    final file = await pickImage(
      context,
      title: "Photo of the log face",
      cameraHint: "Point the camera at the cut end",
      galleryHint: "Pick a photo of the cut end you already took",
    );

    if (file == null || !mounted) return;

    setState(() {
      _capturedImage = XFile(file.path);
      _imageCaptured = true;
    });

    final traced = await _traceFace(file);
    if (traced && mounted) await _plan();
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
      _overlay = null;
    });
  }

  /// Opens the tracing screen for the captured photo.
  ///
  /// This is what makes the photo count. Before it, the picture was only
  /// ever attached to the PDF -- the engine packed into a circle no matter
  /// what the log actually looked like.
  Future<bool> _traceFace(File photo) async {
    final traced = await Navigator.push<LogFaceTraceResult?>(
      context,
      MaterialPageRoute(
        builder: (_) => LogFaceTraceScreen(
          photo: photo,
          initialGirthInches: _tracedGirthInches,
        ),
      ),
    );

    if (!mounted || traced == null) return false;

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

      _overlay = PatternOverlay(
        photo: photo,
        mmPerPixel: traced.inchesPerPixel * mmPerInch,
        faceOriginPx: traced.faceOriginPx,
        imageSize: traced.imageSize,
      );
    });

    return true;
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

    setState(() {
      _measuredLengthMm = result.lengthMm;

      // The scan measures across the face, so the girth follows -- which is
      // exactly the number the tracing screen needs for its scale. The user
      // gets the real shape of the face without touching a tape.
      _tracedGirthInches = math.pi * result.diameterMm / 25.4;
    });

    // The LiDAR screen already took a photograph. Tracing it is what stops
    // a measured log from being packed into a perfect circle -- the gap that
    // made the sensor reading worth less than it should have been.
    final traced = await _traceFace(result.photo);

    if (!mounted) return;

    await _plan(
      fallbackDiameterMm: result.diameterMm,
      lockMeasurements: !traced,
    );
  }

  void _openManualFlow() {
    setState(() => _stage = _Stage.manualCamera);
    _initCamera();
  }

  /// Collects the cut settings, plans both strategies, and shows the result.
  ///
  /// One path for every way of getting here: the only difference between a
  /// LiDAR scan, a traced photo and typed numbers is where the shape and the
  /// scale came from, and by this point both are settled.
  Future<void> _plan({
    double? fallbackDiameterMm,
    bool lockMeasurements = false,
  }) async {
    final traced = _outline;

    // Pre-fill from the trace so the sheet cannot show a diameter that
    // contradicts the shape the user just outlined.
    final setup = await showCuttingSetupSheet(
      context,
      logDiameterMm: traced?.equivalentCircleDiameter ?? fallbackDiameterMm,
      logLengthMm: _measuredLengthMm,
      measuredViaLidar: lockMeasurements,
    );

    if (setup == null || !mounted) return;

    // No photo, or a photo the user chose not to trace: fall back to a
    // circle of the diameter they typed. Same engine, same code path -- only
    // a poorer shape.
    final outline = traced ?? LogFaceOutline.circle(setup.logDiameterMm);

    final request = setup.toRequest(
      outline,
      defects: traced == null ? const [] : _defects,
      avoidDefects: UserPreferencesService.instance.current.avoidDefects,
    );

    setState(() => _planning = true);

    // Off the UI thread: the search is long enough to freeze the screen, and
    // a frozen screen is indistinguishable from a crashed one.
    final comparison = await compute(SawingEngine.planBoth, request);

    if (!mounted) return;
    setState(() => _planning = false);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CuttingResultScreen(
          comparison: comparison,
          overlay: traced == null ? null : _overlay,
          kerfMm: setup.kerfMm,
          defects: traced == null ? const [] : _defects,
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
      // StackFit.expand, so the scroll view inside gets a bounded height and
      // actually scrolls. Under the default loose constraints it sizes to
      // its own content instead, and anything past the bottom of the screen
      // becomes unreachable rather than scrollable.
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: _stage == _Stage.modeSelect
                ? _buildModeSelect()
                : _buildManualCamera(),
          ),
          if (_planning) _buildPlanningOverlay(),
        ],
      ),
    );
  }

  Widget _buildPlanningOverlay() {
    return const ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              "Working out the best way to cut this log…",
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
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
                          onPressed: () async {
                            final traced =
                                await _traceFace(File(_capturedImage!.path));
                            if (traced && mounted) await _plan();
                          },
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
          if (!_imageCaptured) ...[
            // A log photographed earlier is just as good as one taken now,
            // and the measuring often happens back at a desk rather than in
            // the yard.
            TextButton.icon(
              onPressed: _chooseFromGallery,
              icon: const Icon(Icons.photo_library, size: 18),
              label: const Text("Choose a photo from this phone"),
            ),
            TextButton(
              onPressed: () => _plan(),
              child: const Text("Skip photo, enter manually"),
            ),
          ],
        ],
      ),
    );
  }
}
