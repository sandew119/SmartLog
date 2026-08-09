import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../services/log_face_detector.dart';
import '../utils/ellipse_fit.dart';
import '../utils/fitted_image_mapper.dart';

/// What the user traced, in inches, ready for the cutting engine.
class LogFaceTraceResult {
  /// Normalised to its own bounding box origin, in inches.
  final LogFaceOutline outline;

  final List<LogDefect> defects;
  final double girthInches;

  /// Scale of the traced face, so the plan can be drawn back onto the photo
  /// it came from. Without these the result screen would be reduced to
  /// drawing the pattern in an abstract circle again.
  final double inchesPerPixel;

  /// Top-left of the traced face's bounding box, in image pixels. The outline
  /// above is shifted to the origin, and this is the shift that was applied.
  final Offset faceOriginPx;

  final Size imageSize;

  const LogFaceTraceResult({
    required this.outline,
    required this.defects,
    required this.girthInches,
    required this.inchesPerPixel,
    required this.faceOriginPx,
    required this.imageSize,
  });
}

/// Arguments for the off-thread trace. Decoding a phone photo takes long
/// enough to drop frames, so it happens in an isolate.
class _TraceRequest {
  final Uint8List bytes;
  final double x;
  final double y;

  const _TraceRequest(this.bytes, this.x, this.y);
}

class _TraceResponse {
  /// The fitted shape, which is what the handles edit.
  final double centreX;
  final double centreY;
  final double semiMajor;
  final double semiMinor;
  final double rotation;

  /// Per-ray radius as a multiple of the fitted ellipse's radius at that
  /// angle. Carries the log's genuine out-of-roundness through to the editor
  /// instead of flattening it back to a clean ellipse.
  final List<double> radialAdjust;

  final double confidence;
  final int imageWidth;
  final int imageHeight;

  const _TraceResponse({
    required this.centreX,
    required this.centreY,
    required this.semiMajor,
    required this.semiMinor,
    required this.rotation,
    required this.radialAdjust,
    required this.confidence,
    required this.imageWidth,
    required this.imageHeight,
  });
}

/// Top-level so it can run in an isolate. Returns plain numbers rather than
/// model objects, which keeps what crosses the isolate boundary trivial.
_TraceResponse? _traceInBackground(_TraceRequest request) {
  final raw = img.decodeImage(request.bytes);
  if (raw == null) return null;

  // Phone cameras almost never write pixels the right way up -- they write
  // them sideways with an EXIF orientation tag saying how to turn them.
  // Flutter's Image widget honours that tag, the image package does not, so
  // without baking it in, a portrait photo decodes 4000x3000 while the user
  // is looking at 3000x4000. Their tap would then land somewhere else
  // entirely and the trace would come back nonsense, or nothing at all.
  final decoded = img.bakeOrientation(raw);

  final detection = LogFaceDetector.detect(
    image: decoded,
    centre: Offset(request.x, request.y),
  );

  if (detection == null) return null;

  final ellipse = detection.ellipse;
  final points = detection.outline.points;

  final adjust = <double>[];
  for (var i = 0; i < points.length; i++) {
    final angle = 2 * math.pi * i / points.length;
    final base = ellipse.radiusAt(angle);

    adjust.add(
      base <= 0 ? 1.0 : (points[i] - ellipse.centre).distance / base,
    );
  }

  return _TraceResponse(
    centreX: ellipse.centre.dx,
    centreY: ellipse.centre.dy,
    semiMajor: ellipse.semiMajor,
    semiMinor: ellipse.semiMinor,
    rotation: ellipse.rotation,
    radialAdjust: adjust,
    confidence: detection.confidence,
    imageWidth: decoded.width,
    imageHeight: decoded.height,
  );
}

/// The six things a finger can grab.
enum _Handle { centre, majorPlus, majorMinus, minorPlus, minorMinus, rotate }

enum _EditMode { shape, refine, defects }

/// Traces the boundary of a log's cut face so the cutting engine can pack
/// boards into the real shape instead of an assumed circle.
///
/// The flow is deliberately three steps and no more: tap the middle, correct
/// anything that looks wrong, confirm the girth. Everything else -- finding
/// the edge, converting pixels to inches -- happens without being asked for.
class LogFaceTraceScreen extends StatefulWidget {
  final File photo;

  /// Pre-filled when the log came from a stack, so the common path needs no
  /// typing at all.
  final double? initialGirthInches;

  const LogFaceTraceScreen({
    super.key,
    required this.photo,
    this.initialGirthInches,
  });

  @override
  State<LogFaceTraceScreen> createState() => _LogFaceTraceScreenState();
}

class _LogFaceTraceScreenState extends State<LogFaceTraceScreen> {
  /// The fitted shape, in *image pixel* coordinates. Converted to inches only
  /// on the way out, so dragging a handle never accumulates conversion error.
  Ellipse? _shape;

  /// One multiplier per ray, applied to the shape's radius at that angle.
  ///
  /// Keeping the shape and its departures from that shape separate is what
  /// lets the six handles keep working after the brush has been used: moving
  /// a handle moves the whole boundary, and every local correction rides
  /// along with it instead of being wiped out.
  List<double> _radialAdjust = const [];

  final List<LogDefect> _defects = [];

  double _confidence = 0;

  /// The photo's true pixel size, resolved before any tap is possible.
  Size? _imageSize;
  bool _imageLoadFailed = false;

  bool _busy = false;
  _EditMode _mode = _EditMode.shape;
  LogDefectKind _defectKind = LogDefectKind.rot;

  /// Grabbed on pan start and held for the whole gesture.
  ///
  /// This is the entire fix for the old adjustment behaviour, which re-picked
  /// the nearest of 72 points on *every* pan update: a finger crossing the
  /// log would drag one point, let go of it, seize another, and leave a trail
  /// of dents behind it.
  _Handle? _grabbed;

  /// Where the brush is, in image pixels, while it is down. Drawn as a ring
  /// so it is obvious what a stroke will and will not touch.
  Offset? _brushAt;

  late final TextEditingController _girthController = TextEditingController(
    text: widget.initialGirthInches?.toStringAsFixed(1) ?? "",
  );

  static const int _segments = 72;

  /// Touch target radius, in logical pixels. A thumb in a timber yard is
  /// nothing like a mouse pointer.
  static const double _grabRadius = 34;

  /// How far past the boundary the rotation handle floats, in logical pixels,
  /// so it never collides with the resize handle it sits beyond.
  static const double _rotateOffset = 38;

  static const double _brushRadius = 52;

  bool get _hasOutline => _shape != null && _radialAdjust.length == _segments;

  double? get _girthInches {
    final parsed = double.tryParse(_girthController.text.trim());
    return (parsed != null && parsed > 0) ? parsed : null;
  }

  @override
  void initState() {
    super.initState();
    _girthController.addListener(() => setState(() {}));
    _loadImageSize();
  }

  /// Resolves the photo's true pixel dimensions before the user can tap.
  ///
  /// Without this the screen cannot work at all: mapping a tap into image
  /// space needs the image's size, and the size used to be read from the
  /// detection result -- which only runs *after* a tap has been mapped. The
  /// first tap therefore always fell through and nothing ever happened.
  ///
  /// Uses the same FileImage the widget below paints, so the decode is shared
  /// with Flutter's image cache rather than done twice.
  Future<void> _loadImageSize() async {
    final stream = FileImage(widget.photo).resolve(
      const ImageConfiguration(),
    );

    late final ImageStreamListener listener;

    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;

        setState(() {
          _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        if (!mounted) return;

        setState(() => _imageLoadFailed = true);
      },
    );

    stream.addListener(listener);
  }

  @override
  void dispose() {
    _girthController.dispose();
    super.dispose();
  }

  /// Null until the photo's dimensions are known, which is what gates tapping.
  FittedImageMapper? _mapperFor(Size box) {
    final image = _imageSize;
    if (image == null) return null;

    return FittedImageMapper(imageSize: image, boxSize: box);
  }

  // --- the boundary -------------------------------------------------------

  double _angleOf(int i) => 2 * math.pi * i / _segments;

  /// The boundary point for ray [i], in image pixels.
  Offset _outlinePoint(int i) {
    final shape = _shape!;
    final angle = _angleOf(i);
    final radius = shape.radiusAt(angle) * _radialAdjust[i];

    return Offset(
      shape.centre.dx + radius * math.cos(angle),
      shape.centre.dy + radius * math.sin(angle),
    );
  }

  List<Offset> _outlinePoints() =>
      [for (var i = 0; i < _segments; i++) _outlinePoint(i)];

  Future<void> _traceFrom(Offset imagePoint) async {
    setState(() => _busy = true);

    final bytes = await widget.photo.readAsBytes();

    final response = await compute(
      _traceInBackground,
      _TraceRequest(bytes, imagePoint.dx, imagePoint.dy),
    );

    if (!mounted) return;

    if (response == null) {
      setState(() => _busy = false);
      _toast(
          "Couldn't read the log face there. Try tapping nearer the middle.");
      return;
    }

    // The size Flutter reports stays authoritative, because that is what the
    // photo is actually painted at. If the decoder disagrees the outline
    // would be drawn against a different coordinate space than the picture
    // underneath it, so say so rather than showing a subtly wrong overlay.
    final displayed = _imageSize;
    final decodedMismatch = displayed != null &&
        (displayed.width.round() != response.imageWidth ||
            displayed.height.round() != response.imageHeight);

    setState(() {
      _busy = false;
      _confidence = response.confidence;
      _shape = Ellipse(
        centre: Offset(response.centreX, response.centreY),
        semiMajor: response.semiMajor,
        semiMinor: response.semiMinor,
        rotation: response.rotation,
      );
      _radialAdjust = response.radialAdjust.length == _segments
          ? List<double>.of(response.radialAdjust)
          : List<double>.filled(_segments, 1);
    });

    if (decodedMismatch) {
      _toast("This photo's orientation is unusual — check the outline.");
    }
  }

  // --- handles ------------------------------------------------------------

  /// Where each handle sits, in image pixels.
  ///
  /// The rotation handle needs a screen-space offset to float clear of the
  /// resize handle, so the mapper is required to place it.
  Map<_Handle, Offset> _handlePositions(FittedImageMapper mapper) {
    final shape = _shape!;
    final c = shape.centre;

    final along = Offset(math.cos(shape.rotation), math.sin(shape.rotation));
    final across = Offset(-along.dy, along.dx);

    final rotateGapPx = mapper.lengthToScreen(1) <= 0
        ? 0.0
        : _rotateOffset / mapper.lengthToScreen(1);

    return {
      _Handle.centre: c,
      _Handle.majorPlus: c + along * shape.semiMajor,
      _Handle.majorMinus: c - along * shape.semiMajor,
      _Handle.minorPlus: c + across * shape.semiMinor,
      _Handle.minorMinus: c - across * shape.semiMinor,
      _Handle.rotate: c + along * (shape.semiMajor + rotateGapPx),
    };
  }

  /// The handle under [screenPoint], or null when the finger is nowhere near
  /// one. Returning null rather than "whichever was closest" is the point:
  /// a stray touch must do nothing at all.
  _Handle? _handleAt(Offset screenPoint, FittedImageMapper mapper) {
    _Handle? best;
    var bestDistance = _grabRadius;

    _handlePositions(mapper).forEach((handle, imagePoint) {
      final distance = (mapper.toScreen(imagePoint) - screenPoint).distance;

      if (distance <= bestDistance) {
        bestDistance = distance;
        best = handle;
      }
    });

    return best;
  }

  void _moveHandle(_Handle handle, Offset imagePoint) {
    final shape = _shape!;

    if (handle == _Handle.centre) {
      setState(() => _shape = shape.copyWith(centre: imagePoint));
      return;
    }

    final delta = imagePoint - shape.centre;

    final along = Offset(math.cos(shape.rotation), math.sin(shape.rotation));
    final across = Offset(-along.dy, along.dx);

    // A resize handle only ever changes the axis it belongs to; the reach
    // across the other axis is ignored. That is what makes a sloppy drag
    // still do the one comprehensible thing.
    switch (handle) {
      case _Handle.majorPlus:
      case _Handle.majorMinus:
        final reach = (delta.dx * along.dx + delta.dy * along.dy).abs();
        setState(() {
          _shape = shape.copyWith(semiMajor: math.max(reach, 6));
        });

      case _Handle.minorPlus:
      case _Handle.minorMinus:
        final reach = (delta.dx * across.dx + delta.dy * across.dy).abs();
        setState(() {
          _shape = shape.copyWith(semiMinor: math.max(reach, 6));
        });

      case _Handle.rotate:
        if (delta.distance < 1) return;
        setState(() {
          _shape = shape.copyWith(rotation: math.atan2(delta.dy, delta.dx));
        });

      case _Handle.centre:
        break;
    }
  }

  // --- the refine brush ---------------------------------------------------

  /// Pushes the boundary toward the finger, but only where the finger is.
  ///
  /// Every point the brush touches is moved along its own ray, so the
  /// boundary stays a well-behaved star shape and can never fold over itself
  /// no matter how wild the stroke.
  void _brush(Offset imagePoint, double radiusInImagePixels) {
    final shape = _shape!;
    final adjusted = List<double>.of(_radialAdjust);

    for (var i = 0; i < _segments; i++) {
      final current = _outlinePoint(i);
      final distance = (current - imagePoint).distance;

      if (distance > radiusInImagePixels) continue;

      final angle = _angleOf(i);
      final base = shape.radiusAt(angle);
      if (base <= 0) continue;

      // Project the finger onto this ray: how far out the user is asking
      // this particular part of the boundary to sit.
      final target = (imagePoint.dx - shape.centre.dx) * math.cos(angle) +
          (imagePoint.dy - shape.centre.dy) * math.sin(angle);

      if (target <= 0) continue;

      // Cosine falloff, so a stroke leaves a smooth dent rather than a step.
      final weight =
          (math.cos(math.pi * distance / radiusInImagePixels) + 1) / 2;

      final wanted = target / base;
      adjusted[i] =
          (adjusted[i] + (wanted - adjusted[i]) * weight).clamp(0.35, 2.5);
    }

    setState(() {
      _radialAdjust = adjusted;
      _brushAt = imagePoint;
    });
  }

  void _tapDefect(Offset imagePoint) {
    // Tapping an existing defect removes it -- the same gesture both ways,
    // so there is no delete mode to discover.
    final existing = _defects.indexWhere(
      (d) => (d.centre - imagePoint).distance <= d.radius,
    );

    setState(() {
      if (existing >= 0) {
        _defects.removeAt(existing);
        return;
      }

      // Sized relative to the face so it is a sensible blob on any photo.
      final outline = LogFaceOutline(_outlinePoints());
      final radius = outline.equivalentCircleDiameter * 0.08;

      _defects.add(
        LogDefect(
          kind: _defectKind,
          centre: imagePoint,
          radius: math.max(radius, 8),
        ),
      );
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _confirm() {
    final girth = _girthInches;
    final size = _imageSize;
    if (!_hasOutline || girth == null || size == null) return;

    final pixels = LogFaceOutline(_outlinePoints());
    final scaled = pixels.scaledToGirth(girth);

    if (scaled == null) {
      _toast("That outline can't be measured. Trace it again.");
      return;
    }

    // Defects have to ride the identical transform, or they would land in
    // the wrong place on the scaled face and block the wrong boards.
    final factor = girth / pixels.perimeter;
    final pixelBounds = pixels.bounds;
    final bounds = pixels.scaled(factor).bounds;

    final defects = [
      for (final d in _defects)
        d.scaled(factor).translated(Offset(-bounds.left, -bounds.top)),
    ];

    Navigator.pop(
      context,
      LogFaceTraceResult(
        outline: scaled,
        defects: defects,
        girthInches: girth,
        inchesPerPixel: factor,
        faceOriginPx: pixelBounds.topLeft,
        imageSize: size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _hasOutline && _girthInches != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_hasOutline ? "Check the Outline" : "Trace the Log Face"),
        actions: [
          if (_hasOutline)
            TextButton(
              onPressed: () => setState(() {
                _shape = null;
                _radialAdjust = const [];
                _defects.clear();
                _confidence = 0;
                _mode = _EditMode.shape;
              }),
              child: const Text(
                "Retrace",
                style: TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildCanvas()),
          _buildControls(ready),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final mapper = _mapperFor(box);

        final brushInImagePixels =
            mapper == null || mapper.lengthToScreen(1) <= 0
                ? 0.0
                : _brushRadius / mapper.lengthToScreen(1);

        void onDown(Offset local) {
          if (mapper == null || _busy) return;

          final point = mapper.toImage(local);
          if (point == null) return;

          if (!_hasOutline) {
            _traceFrom(point);
            return;
          }

          switch (_mode) {
            case _EditMode.shape:
              setState(() => _grabbed = _handleAt(local, mapper));

            case _EditMode.refine:
              _brush(point, brushInImagePixels);

            case _EditMode.defects:
              _tapDefect(point);
          }
        }

        void onMove(Offset local) {
          if (mapper == null || _busy || !_hasOutline) return;

          final point = mapper.toImage(local);
          if (point == null) return;

          switch (_mode) {
            case _EditMode.shape:
              final grabbed = _grabbed;
              // Nothing grabbed means the pan started on empty photo. Doing
              // nothing is the correct answer, and is exactly what the old
              // screen refused to do.
              if (grabbed != null) _moveHandle(grabbed, point);

            case _EditMode.refine:
              _brush(point, brushInImagePixels);

            case _EditMode.defects:
              break;
          }
        }

        void onUp() {
          if (_grabbed != null || _brushAt != null) {
            setState(() {
              _grabbed = null;
              _brushAt = null;
            });
          }
        }

        // Pan callbacks only, deliberately. `onPanDown` already fires on
        // every pointer down, tap or not, so adding tap callbacks alongside
        // them does two kinds of damage: a plain tap runs `onDown` twice --
        // marking a defect and immediately unmarking it -- and the moment a
        // drag passes the tap slop the tap recogniser cancels, which used to
        // let go of the handle the drag had just taken hold of.
        return GestureDetector(
          // Keyed so a test can find the drawing surface and work out where
          // the handles are on screen.
          key: const ValueKey("trace-canvas"),
          onPanDown: (d) => onDown(d.localPosition),
          onPanUpdate: (d) => onMove(d.localPosition),
          onPanEnd: (_) => onUp(),
          onPanCancel: onUp,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(widget.photo, fit: BoxFit.contain),
              if (_hasOutline && mapper != null)
                CustomPaint(
                  painter: _OutlinePainter(
                    points: [
                      for (final p in _outlinePoints()) mapper.toScreen(p),
                    ],
                    handles: _mode == _EditMode.shape
                        ? {
                            for (final entry
                                in _handlePositions(mapper).entries)
                              entry.key: mapper.toScreen(entry.value),
                          }
                        : const {},
                    grabbed: _grabbed,
                    brushCentre:
                        _brushAt == null ? null : mapper.toScreen(_brushAt!),
                    brushRadius: _brushRadius,
                    defects: [
                      for (final d in _defects)
                        (
                          centre: mapper.toScreen(d.centre),
                          radius: mapper.lengthToScreen(d.radius),
                          colour: _colourFor(d.kind),
                        ),
                    ],
                  ),
                ),
              if (!_hasOutline && !_busy) _buildPrompt(),
              if (_hasOutline) _buildModeHint(),
              if (_busy)
                const ColoredBox(
                  color: Colors.black54,
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Pinned to the top, never the centre.
  ///
  /// It used to sit dead centre, which is precisely where the user has to
  /// look and tap -- the instruction was covering the thing it was
  /// instructing about.
  Widget _buildPrompt() {
    final waiting = _imageSize == null && !_imageLoadFailed;

    return _banner(
      icon: _imageLoadFailed
          ? Icons.broken_image
          : (waiting ? Icons.hourglass_empty : Icons.touch_app),
      text: _imageLoadFailed
          ? "That photo couldn't be opened. Go back and retake it."
          : (waiting ? "Opening the photo…" : "Tap the middle of the cut face"),
    );
  }

  Widget _buildModeHint() {
    return _banner(
      icon: switch (_mode) {
        _EditMode.shape => Icons.open_with,
        _EditMode.refine => Icons.brush,
        _EditMode.defects => Icons.report_problem_outlined,
      },
      text: switch (_mode) {
        _EditMode.shape =>
          "Drag a white dot to resize, the middle to move, the arrow to turn",
        _EditMode.refine =>
          "Drag along the edge to push the outline onto the log",
        _EditMode.defects => "Tap a flaw to mark it, tap it again to remove it",
      },
    );
  }

  Widget _banner({required IconData icon, required String text}) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _colourFor(LogDefectKind kind) => switch (kind) {
        LogDefectKind.rot => Colors.redAccent,
        LogDefectKind.hollow => Colors.deepOrange,
        LogDefectKind.crack => Colors.amber,
        LogDefectKind.shake => Colors.purpleAccent,
        LogDefectKind.knot => Colors.lightBlueAccent,
      };

  Widget _buildControls(bool ready) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_hasOutline && _confidence < 0.7)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber,
                          color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "The face didn't stand out clearly from its "
                          "background (${(_confidence * 100).round()}% of the "
                          "edge was found). Check the outline before going on.",
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_hasOutline) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _girthController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: "Girth",
                          suffixText: "in",
                          isDense: true,
                          border: OutlineInputBorder(),
                          helperText: "Tape measurement — sets the scale",
                          helperMaxLines: 2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _sizeSummary()),
                  ],
                ),
                const SizedBox(height: 10),
                SegmentedButton<_EditMode>(
                  segments: const [
                    ButtonSegment(
                      value: _EditMode.shape,
                      icon: Icon(Icons.open_with, size: 18),
                      label: Text("Adjust"),
                    ),
                    ButtonSegment(
                      value: _EditMode.refine,
                      icon: Icon(Icons.brush, size: 18),
                      label: Text("Refine"),
                    ),
                    ButtonSegment(
                      value: _EditMode.defects,
                      icon: Icon(Icons.report_problem_outlined, size: 18),
                      label: Text("Defects"),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() {
                    _mode = s.first;
                    _grabbed = null;
                    _brushAt = null;
                  }),
                ),
                if (_mode == _EditMode.refine) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _isRefined
                              ? "Local corrections are kept when you move or "
                                  "resize the outline."
                              : "For logs that aren't round — a flat side, or "
                                  "a dent where a branch came off.",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                      if (_isRefined)
                        TextButton(
                          onPressed: () => setState(() {
                            _radialAdjust = List<double>.filled(_segments, 1);
                          }),
                          child: const Text("Undo all"),
                        ),
                    ],
                  ),
                ],
                if (_mode == _EditMode.defects) ...[
                  const SizedBox(height: 8),
                  _defectKindPicker(),
                ],
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: ready ? _confirm : null,
                  icon: const Icon(Icons.check),
                  label: Text(
                    !_hasOutline
                        ? "Tap the log face to begin"
                        : (_girthInches == null
                            ? "Enter the girth to continue"
                            : "Use This Outline"),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isRefined => _radialAdjust.any((a) => (a - 1).abs() > 0.005);

  /// Shows what the trace actually bought, in the units a sawyer thinks in.
  Widget _sizeSummary() {
    final girth = _girthInches;
    if (!_hasOutline || girth == null) {
      return const SizedBox.shrink();
    }

    final scaled = LogFaceOutline(_outlinePoints()).scaledToGirth(girth);
    if (scaled == null) return const SizedBox.shrink();

    final axes = scaled.axes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "${axes.major.toStringAsFixed(1)} × "
          "${axes.minor.toStringAsFixed(1)} in",
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        Text(
          _defects.isEmpty
              ? "widest × narrowest"
              : "${_defects.length} defect${_defects.length == 1 ? '' : 's'} marked",
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _defectKindPicker() {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final kind in LogDefectKind.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(kind.label),
                selected: _defectKind == kind,
                avatar: CircleAvatar(
                  backgroundColor: _colourFor(kind),
                  radius: 6,
                ),
                onSelected: (_) => setState(() => _defectKind = kind),
              ),
            ),
        ],
      ),
    );
  }
}

class _OutlinePainter extends CustomPainter {
  final List<Offset> points;

  /// Empty outside shape-editing mode: showing grab targets that do nothing
  /// is worse than showing none.
  final Map<_Handle, Offset> handles;

  final _Handle? grabbed;

  final Offset? brushCentre;
  final double brushRadius;

  final List<({Offset centre, double radius, Color colour})> defects;

  const _OutlinePainter({
    required this.points,
    required this.handles,
    required this.grabbed,
    required this.brushCentre,
    required this.brushRadius,
    required this.defects,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 3) return;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()..color = Colors.lightGreenAccent.withValues(alpha: 0.18),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.lightGreenAccent,
    );

    final rotateHandle = handles[_Handle.rotate];
    final centreHandle = handles[_Handle.centre];

    // A stalk from the middle out to the rotation handle, so it reads as a
    // lever rather than a stray dot floating off the log.
    if (rotateHandle != null && centreHandle != null) {
      canvas.drawLine(
        centreHandle,
        rotateHandle,
        Paint()
          ..strokeWidth = 1.5
          ..color = Colors.white54,
      );
    }

    handles.forEach((handle, position) {
      final active = handle == grabbed;
      final radius = active ? 13.0 : 9.0;

      canvas.drawCircle(
        position,
        radius + 3,
        Paint()..color = Colors.black.withValues(alpha: 0.35),
      );

      canvas.drawCircle(
        position,
        radius,
        Paint()..color = active ? Colors.yellowAccent : Colors.white,
      );

      canvas.drawCircle(
        position,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.green.shade700,
      );

      final glyph = switch (handle) {
        _Handle.centre => Icons.open_with,
        _Handle.rotate => Icons.rotate_right,
        _ => null,
      };

      if (glyph == null) return;

      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(glyph.codePoint),
          style: TextStyle(
            fontSize: radius * 1.3,
            fontFamily: glyph.fontFamily,
            package: glyph.fontPackage,
            color: Colors.green.shade800,
          ),
        ),
      )..layout();

      painter.paint(
        canvas,
        position - Offset(painter.width / 2, painter.height / 2),
      );
    });

    if (brushCentre != null) {
      canvas.drawCircle(
        brushCentre!,
        brushRadius,
        Paint()..color = Colors.yellowAccent.withValues(alpha: 0.15),
      );
      canvas.drawCircle(
        brushCentre!,
        brushRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.yellowAccent,
      );
    }

    for (final defect in defects) {
      canvas.drawCircle(
        defect.centre,
        defect.radius,
        Paint()..color = defect.colour.withValues(alpha: 0.35),
      );
      canvas.drawCircle(
        defect.centre,
        defect.radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = defect.colour,
      );
    }
  }

  @override
  bool shouldRepaint(_OutlinePainter old) =>
      old.points != points ||
      old.handles != handles ||
      old.grabbed != grabbed ||
      old.brushCentre != brushCentre ||
      old.defects != defects;
}
