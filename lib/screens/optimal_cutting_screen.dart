import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../services/lidar_service.dart';
import '../services/sawing_engine.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
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
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: 16),
              Text(
                "Planning the cut",
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 6),
              Text(
                "Working out the best way to cut this log…",
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeSelect() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "How would you like to measure the log?",
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            "A photo of the log is required for LiDAR scanning. For manual "
            "entry, taking a photo is recommended but optional.",
            style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 24),
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
            badge: _lidarAvailable ? "PRO" : null,
            onTap: _openLiDARFlow,
          ),
          const SizedBox(height: 14),
          _modeCard(
            title: "Manual Measurements",
            subtitle:
                "Enter the log's diameter and length yourself, with an optional photo.",
            icon: Icons.rule,
            enabled: true,
            highlighted: !_lidarAvailable,
            onTap: _openManualFlow,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.tips_and_updates_outlined,
                    color: AppTheme.primaryBright, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "A photo lets SmartLog trace the real shape of the face — "
                    "oval and flat-sided logs yield more than a circle "
                    "would suggest.",
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
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
    String? badge,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge - 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge - 4),
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onTap();
                }
              : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge - 4),
              border: Border.all(
                color: highlighted ? AppTheme.primaryBright : AppTheme.line,
                width: highlighted ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    gradient: highlighted ? AppTheme.brandGradient : null,
                    color: highlighted ? null : AppTheme.surfaceMuted,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    icon,
                    color: highlighted ? Colors.white : AppTheme.textSecondary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                gradient: AppTheme.timberGradient,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                badge,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppTheme.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The live camera, filling a square without being stretched into it.
  ///
  /// This is the fix for the skewed picture. The preview used to be dropped
  /// straight into a fixed 300 x 300 box, and a tight square constraint
  /// overrides CameraPreview's own aspect ratio -- so a 4:3 sensor image was
  /// squashed into 1:1 and every log looked oval. Here the preview is laid
  /// out at its true proportions and then *cropped* to the square, the way
  /// every camera app's viewfinder works.
  Widget _livePreview(CameraController controller) {
    final preview = controller.value.previewSize;

    // previewSize is reported sensor-side, i.e. landscape. On a phone held
    // upright the picture is the other way round.
    final width = preview == null
        ? 3.0
        : math.min(preview.width, preview.height).toDouble();
    final height = preview == null
        ? 4.0
        : math.max(preview.width, preview.height).toDouble();

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: width,
          height: height,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  Widget _buildManualCamera() {
    Widget cameraPreview;

    if (_cameraLoading) {
      cameraPreview = const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    } else if (!_cameraReady) {
      cameraPreview = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined,
                color: Colors.white54, size: 36),
            SizedBox(height: 10),
            Text(
              "Camera not available",
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    } else if (_imageCaptured) {
      // The whole photo, letterboxed: what gets traced is exactly this.
      cameraPreview = Image.file(
        File(_capturedImage!.path),
        fit: BoxFit.contain,
      );
    } else {
      cameraPreview = _livePreview(_cameraController!);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        children: [
          Text(
            _imageCaptured ? "Photo captured" : "Photograph the cut end",
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            _imageCaptured
                ? "Trace the face next, or retake if it isn't sharp."
                : "Fill the circle with the log's cut face. A photo is "
                    "optional — you can skip it below.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(constraints.maxWidth, 420.0);

              return Center(
                child: SizedBox(
                  width: side,
                  height: side,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Color(0xFF0E1411)),
                        cameraPreview,
                        if (!_imageCaptured && _cameraReady)
                          const IgnorePointer(
                            child: CustomPaint(painter: _ViewfinderPainter()),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 22),
          if (_imageCaptured)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _retake,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text("Retake"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final traced =
                          await _traceFace(File(_capturedImage!.path));
                      if (traced && mounted) await _plan();
                    },
                    icon: const Icon(Icons.gesture_rounded),
                    label: const Text("Trace Face"),
                  ),
                ),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _roundAction(
                  icon: Icons.photo_library_outlined,
                  label: "Gallery",
                  onTap: _chooseFromGallery,
                ),
                _ShutterButton(
                  enabled: _cameraReady,
                  onTap: _captureImage,
                ),
                _roundAction(
                  icon: Icons.keyboard_alt_outlined,
                  label: "Manual",
                  onTap: () => _plan(),
                ),
              ],
            ),
          const SizedBox(height: 14),
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

  Widget _roundAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.white,
          shape: const CircleBorder(side: BorderSide(color: AppTheme.line)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child: Icon(icon, color: AppTheme.primary),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The capture button: a white disc in a ring, like a camera's own.
class _ShutterButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _ShutterButton({required this.enabled, required this.onTap});

  @override
  State<_ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends State<_ShutterButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: "Capture Log Surface",
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: widget.enabled ? (_) => setState(() => _down = false) : null,
        onTap: widget.enabled
            ? () {
                HapticFeedback.mediumImpact();
                widget.onTap();
              }
            : null,
        child: Opacity(
          opacity: widget.enabled ? 1 : 0.4,
          child: Container(
            width: 78,
            height: 78,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.primary, width: 3),
            ),
            child: AnimatedScale(
              scale: _down ? 0.88 : 1,
              duration: const Duration(milliseconds: 110),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppTheme.brandGradient,
                ),
                child: const Icon(
                  Icons.camera_alt_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dims everything outside a centred circle and marks the corners, so the
/// user knows exactly where the cut face should sit.
class _ViewfinderPainter extends CustomPainter {
  const _ViewfinderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide * 0.4;

    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: centre, radius: radius));

    canvas.drawPath(
        scrim, Paint()..color = Colors.black.withValues(alpha: 0.38));

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white.withValues(alpha: 0.9),
    );

    // Corner brackets.
    const inset = 16.0;
    const arm = 26.0;
    final bracket = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;

    for (final corner in [
      const Offset(inset, inset),
      Offset(size.width - inset, inset),
      Offset(inset, size.height - inset),
      Offset(size.width - inset, size.height - inset),
    ]) {
      final dx = corner.dx < size.width / 2 ? arm : -arm;
      final dy = corner.dy < size.height / 2 ? arm : -arm;

      canvas.drawLine(corner, corner + Offset(dx, 0), bracket);
      canvas.drawLine(corner, corner + Offset(0, dy), bracket);
    }

    // A small crosshair where the pith should be.
    final cross = Paint()
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.7);

    canvas.drawLine(
        centre - const Offset(8, 0), centre + const Offset(8, 0), cross);
    canvas.drawLine(
        centre - const Offset(0, 8), centre + const Offset(0, 8), cross);
  }

  @override
  bool shouldRepaint(_ViewfinderPainter oldDelegate) => false;
}
