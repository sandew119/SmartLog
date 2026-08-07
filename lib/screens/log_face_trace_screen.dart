import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../services/log_face_detector.dart';

/// What the user traced, in inches, ready for the cutting engine.
class LogFaceTraceResult {
  final LogFaceOutline outline;
  final List<LogDefect> defects;
  final double girthInches;

  const LogFaceTraceResult({
    required this.outline,
    required this.defects,
    required this.girthInches,
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
  final List<double> flatPoints;
  final double confidence;
  final int imageWidth;
  final int imageHeight;

  const _TraceResponse({
    required this.flatPoints,
    required this.confidence,
    required this.imageWidth,
    required this.imageHeight,
  });
}

/// Top-level so it can run in an isolate. Returns plain numbers rather than
/// model objects, which keeps what crosses the isolate boundary trivial.
_TraceResponse? _traceInBackground(_TraceRequest request) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) return null;

  final detection = LogFaceDetector.detect(
    image: decoded,
    centre: Offset(request.x, request.y),
  );

  if (detection == null) return null;

  return _TraceResponse(
    flatPoints: [
      for (final p in detection.outline.points) ...[p.dx, p.dy],
    ],
    confidence: detection.confidence,
    imageWidth: decoded.width,
    imageHeight: decoded.height,
  );
}

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
  /// Outline in *image pixel* coordinates. Converted to inches only on the
  /// way out, so dragging a handle never accumulates conversion error.
  List<Offset> _points = const [];

  final List<LogDefect> _defects = [];

  double _confidence = 0;
  Size? _imageSize;

  bool _busy = false;
  bool _markingDefects = false;
  LogDefectKind _defectKind = LogDefectKind.rot;

  late final TextEditingController _girthController = TextEditingController(
    text: widget.initialGirthInches?.toStringAsFixed(1) ?? "",
  );

  /// How far, in outline points, a drag drags its neighbours. Without this
  /// every handle would have to be moved individually to fix one bad patch.
  static const int _dragFalloff = 4;

  /// One handle every N points. 72 handles would be unusable on a phone.
  static const int _handleEvery = 6;

  bool get _hasOutline => _points.length >= 3;

  double? get _girthInches {
    final parsed = double.tryParse(_girthController.text.trim());
    return (parsed != null && parsed > 0) ? parsed : null;
  }

  @override
  void initState() {
    super.initState();
    _girthController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _girthController.dispose();
    super.dispose();
  }

  /// Maps the photo's pixel space onto the box it is displayed in.
  ///
  /// The image is letterboxed with BoxFit.contain, so a tap has to be
  /// un-letterboxed before it means anything in image coordinates.
  Rect _displayRect(Size box) {
    final image = _imageSize;
    if (image == null) return Offset.zero & box;

    final scale = math.min(box.width / image.width, box.height / image.height);
    final w = image.width * scale;
    final h = image.height * scale;

    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Offset? _toImageSpace(Offset local, Size box) {
    final rect = _displayRect(box);
    if (!rect.contains(local) || _imageSize == null) return null;

    final scale = _imageSize!.width / rect.width;

    return Offset(
      (local.dx - rect.left) * scale,
      (local.dy - rect.top) * scale,
    );
  }

  Offset _toScreenSpace(Offset image, Size box) {
    final rect = _displayRect(box);
    if (_imageSize == null) return image;

    final scale = rect.width / _imageSize!.width;

    return Offset(rect.left + image.dx * scale, rect.top + image.dy * scale);
  }

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
      _toast("Couldn't read the log face there. Try tapping nearer the middle.");
      return;
    }

    setState(() {
      _busy = false;
      _confidence = response.confidence;
      _imageSize = Size(
        response.imageWidth.toDouble(),
        response.imageHeight.toDouble(),
      );
      _points = [
        for (var i = 0; i < response.flatPoints.length; i += 2)
          Offset(response.flatPoints[i], response.flatPoints[i + 1]),
      ];
    });
  }

  /// Drags the nearest outline point, pulling its neighbours along with a
  /// cosine falloff so the boundary stays smooth instead of growing spikes.
  void _dragOutline(Offset imagePoint) {
    if (!_hasOutline) return;

    var nearest = 0;
    var best = double.infinity;

    for (var i = 0; i < _points.length; i++) {
      final d = (_points[i] - imagePoint).distanceSquared;
      if (d < best) {
        best = d;
        nearest = i;
      }
    }

    final delta = imagePoint - _points[nearest];
    final updated = List<Offset>.of(_points);

    for (var offset = -_dragFalloff; offset <= _dragFalloff; offset++) {
      final index = (nearest + offset + _points.length) % _points.length;

      final weight =
          (math.cos(math.pi * offset / (_dragFalloff + 1)) + 1) / 2;

      updated[index] = _points[index] + delta * weight;
    }

    setState(() => _points = updated);
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
      final outline = LogFaceOutline(_points);
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
    if (!_hasOutline || girth == null) return;

    final pixels = LogFaceOutline(_points);
    final scaled = pixels.scaledToGirth(girth);

    if (scaled == null) {
      _toast("That outline can't be measured. Trace it again.");
      return;
    }

    // Defects have to ride the identical transform, or they would land in
    // the wrong place on the scaled face and block the wrong boards.
    final factor = girth / pixels.perimeter;
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
                _points = const [];
                _defects.clear();
                _confidence = 0;
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

        void handle(Offset local, {required bool drag}) {
          final point = _toImageSpace(local, box);
          if (point == null || _busy) return;

          if (!_hasOutline) {
            if (!drag) _traceFrom(point);
            return;
          }

          if (_markingDefects) {
            if (!drag) _tapDefect(point);
          } else {
            _dragOutline(point);
          }
        }

        return GestureDetector(
          onTapDown: (d) => handle(d.localPosition, drag: false),
          onPanUpdate: (d) => handle(d.localPosition, drag: true),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(widget.photo, fit: BoxFit.contain),
              if (_hasOutline)
                CustomPaint(
                  painter: _OutlinePainter(
                    points: [
                      for (final p in _points) _toScreenSpace(p, box),
                    ],
                    handleEvery: _handleEvery,
                    defects: [
                      for (final d in _defects)
                        (
                          centre: _toScreenSpace(d.centre, box),
                          radius: d.radius *
                              (_displayRect(box).width /
                                  (_imageSize?.width ?? 1)),
                          colour: _colourFor(d.kind),
                        ),
                    ],
                  ),
                ),
              if (!_hasOutline && !_busy) _buildPrompt(),
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

  Widget _buildPrompt() {
    return IgnorePointer(
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.touch_app, color: Colors.white, size: 34),
              SizedBox(height: 10),
              Text(
                "Tap the middle of the cut face",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 6),
              Text(
                "The outline is found from there. You can drag it afterwards.",
                style: TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
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
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.gesture, size: 18),
                            label: Text("Outline"),
                          ),
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.report_problem_outlined, size: 18),
                            label: Text("Defects"),
                          ),
                        ],
                        selected: {_markingDefects},
                        onSelectionChanged: (s) =>
                            setState(() => _markingDefects = s.first),
                      ),
                    ),
                  ],
                ),
                if (_markingDefects) ...[
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

  /// Shows what the trace actually bought, in the units a sawyer thinks in.
  Widget _sizeSummary() {
    final girth = _girthInches;
    if (!_hasOutline || girth == null) {
      return const SizedBox.shrink();
    }

    final scaled = LogFaceOutline(_points).scaledToGirth(girth);
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
  final int handleEvery;
  final List<({Offset centre, double radius, Color colour})> defects;

  const _OutlinePainter({
    required this.points,
    required this.handleEvery,
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

    for (var i = 0; i < points.length; i += handleEvery) {
      canvas.drawCircle(points[i], 7, Paint()..color = Colors.white);
      canvas.drawCircle(
        points[i],
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.green.shade700,
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
      old.points != points || old.defects != defects;
}
