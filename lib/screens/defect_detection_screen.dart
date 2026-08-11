import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../database/local_db.dart';
import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../models/sawing_models.dart';
import '../painters/defect_overlay_painter.dart';
import '../services/defect_detector.dart';
import '../services/defect_impact.dart';
import '../services/diagnostics_service.dart';
import '../utils/image_quality.dart';
import '../widgets/image_source_sheet.dart';

/// Decoding a phone photograph takes long enough to drop frames, so it and
/// the quality measurement happen off the UI thread.
class _PreparedImage {
  final img.Image image;
  final ImageQuality quality;

  const _PreparedImage(this.image, this.quality);
}

_PreparedImage? _prepare(Uint8ListWrapper request) {
  final raw = img.decodeImage(request.bytes);
  if (raw == null) return null;

  // Phone cameras write pixels sideways with an EXIF tag saying how to turn
  // them. Flutter honours the tag; the image package does not. Without
  // baking it in, a portrait photo is analysed rotated.
  final decoded = img.bakeOrientation(raw);

  return _PreparedImage(decoded, ImageQualityChecker.assess(decoded));
}

/// Wrapper so the isolate payload is one object.
class Uint8ListWrapper {
  final Uint8List bytes;
  const Uint8ListWrapper(this.bytes);
}

/// Finds and explains surface defects on a log.
///
/// The screen is built so the model is the only missing piece: capture,
/// quality gating, overlay, severity, impact and persistence all work today
/// and are exercised by the defects a user marks by hand. When the trained
/// network is installed it slots in behind [DefectDetector] and nothing
/// here changes.
class DefectDetectionScreen extends StatefulWidget {
  /// The traced face, when the user arrived from the cutting flow. With it,
  /// the screen can say what a defect costs in board volume; without it, it
  /// can only say what the defect is.
  final LogFaceOutline? outline;
  final SawingSetup? setup;

  /// The log these findings belong to, when there is one to attach them to.
  final int? logId;

  const DefectDetectionScreen({
    super.key,
    this.outline,
    this.setup,
    this.logId,
  });

  @override
  State<DefectDetectionScreen> createState() => _DefectDetectionScreenState();
}

class _DefectDetectionScreenState extends State<DefectDetectionScreen> {
  File? _file;
  ui.Image? _photo;
  Size? _imageSize;

  ImageQuality? _quality;
  DefectAnalysis? _analysis;
  List<DefectImpact> _impacts = const [];

  bool _busy = false;
  bool _showHeatmap = true;
  String? _error;

  DefectDetector get _detector => DefectDetection.instance;

  // --- picking and analysing ------------------------------------------------

  Future<void> _pick() async {
    final file = await pickImage(
      context,
      title: "Photograph the log surface",
      cameraHint: "Fill the frame with the timber, in good light",
      galleryHint: "Use a photo you already took of this log",
    );

    if (file == null || !mounted) return;

    setState(() {
      _file = file;
      _photo = null;
      _analysis = null;
      _impacts = const [];
      _quality = null;
      _error = null;
      _busy = true;
    });

    await _analyse(file);
  }

  Future<void> _analyse(File file) async {
    try {
      final bytes = await file.readAsBytes();

      final prepared = await compute(_prepare, Uint8ListWrapper(bytes));

      if (!mounted) return;

      if (prepared == null) {
        setState(() {
          _busy = false;
          _error = "That file isn't an image this app can read.";
        });
        return;
      }

      setState(() {
        _quality = prepared.quality;
        _imageSize = Size(
          prepared.image.width.toDouble(),
          prepared.image.height.toDouble(),
        );
      });

      unawaitedLoad(file);

      // Refuse before inference, not after. A model has no way to say "I
      // cannot see" -- it will return a confident answer for a blurred
      // photograph of nothing, and a wrong answer about rot is worse than
      // no answer.
      if (!prepared.quality.isUsable) {
        setState(() => _busy = false);
        return;
      }

      if (!_detector.isAvailable) {
        setState(() => _busy = false);
        return;
      }

      final analysis = await DiagnosticsService.instance.timed(
        DiagnosticsService.moduleDefects,
        () => _detector.analyse(prepared.image),
      );

      if (!mounted) return;

      setState(() {
        _analysis = analysis;
        _busy = false;
      });

      await _measureImpact(analysis, prepared.image);
    } catch (error) {
      await DiagnosticsService.instance.recordError(
        module: DiagnosticsService.moduleDefects,
        error: error,
      );

      if (!mounted) return;

      setState(() {
        _busy = false;
        // The raw exception goes to the diagnostic store, never to the user.
        _error = "Something went wrong reading that photo. Try another one.";
      });
    }
  }

  /// Loads the photo for painting, through Flutter's own pipeline so the
  /// EXIF interpretation matches what the overlay is drawn against.
  void unawaitedLoad(File file) {
    final stream = FileImage(file).resolve(const ImageConfiguration());

    late final ImageStreamListener listener;

    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;
        setState(() => _photo = info.image);
      },
      onError: (_, __) => stream.removeListener(listener),
    );

    stream.addListener(listener);
  }

  /// What each finding costs, when there is a traced face to measure against.
  Future<void> _measureImpact(DefectAnalysis analysis, img.Image image) async {
    final outline = widget.outline;
    final setup = widget.setup;

    if (outline == null || setup == null) return;
    if (analysis.actionable.isEmpty) return;

    // Findings are in image pixels; the outline is in millimetres. Scale by
    // the ratio of their widths, which is exact because both describe the
    // same face.
    final scale = image.width <= 0 ? 1.0 : outline.bounds.width / image.width;

    final defects = [
      for (final finding in analysis.actionable)
        finding.toDefect().scaled(scale),
    ];

    final impacts = const DefectImpactAnalyser().analyse(
      outline: outline,
      defects: defects,
      setup: setup,
    );

    if (!mounted) return;
    setState(() => _impacts = impacts);
  }

  Future<void> _save() async {
    final analysis = _analysis;
    final logId = widget.logId;

    if (analysis == null || logId == null) return;

    setState(() => _busy = true);

    try {
      for (var i = 0; i < analysis.actionable.length; i++) {
        final finding = analysis.actionable[i];

        await LocalDB.saveDefect(
          logId: logId,
          kind: finding.kind.name,
          confidence: finding.confidence,
          automatic: true,
          centreX: finding.region.center.dx,
          centreY: finding.region.center.dy,
          radius: finding.region.longestSide / 2,
          imagePath: _file?.path,
          severity: i < _impacts.length ? _impacts[i].severity.stored : null,
        );
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Saved ${analysis.actionable.length} defect"
            "${analysis.actionable.length == 1 ? '' : 's'} to this log.",
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- UI -------------------------------------------------------------------

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.center_focus_weak, size: 72, color: Colors.grey),
            const SizedBox(height: 20),
            const Text(
              "Check a log for defects",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Take a photo of the cut face or the surface, or pick one you "
              "already have. Fill the frame with timber and use good light.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.add_a_photo),
                label: const Text("Add a photo"),
              ),
            ),
            const SizedBox(height: 20),
            _modelBadge(),
          ],
        ),
      ),
    );
  }

  /// Says plainly what is running. "It found nothing" and "nothing is
  /// looking" must never look the same.
  Widget _modelBadge() {
    final available = _detector.isAvailable;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            (available ? Colors.green : Colors.orange).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            available ? Icons.memory : Icons.info_outline,
            size: 18,
            color: available ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              available
                  ? "Model: ${_detector.name}"
                  : "No detection model is installed yet. You can still "
                      "photograph a log and mark defects by hand while "
                      "tracing the face.",
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _photoCard() {
    final photo = _photo;
    final size = _imageSize;

    if (photo == null || size == null) {
      return const AspectRatio(
        aspectRatio: 4 / 3,
        child: ColoredBox(
          color: Colors.black12,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final analysis = _analysis;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: (size.width / size.height).clamp(0.6, 1.9),
        child: InteractiveViewer(
          maxScale: 5,
          child: CustomPaint(
            size: Size.infinite,
            painter: DefectOverlayPainter(
              photo: photo,
              imageSize: size,
              findings: analysis?.findings ?? const [],
              severities: [for (final i in _impacts) i.severity],
              activation: analysis?.activation,
              activationWidth: analysis?.activationWidth ?? 0,
              activationHeight: analysis?.activationHeight ?? 0,
              showHeatmap: _showHeatmap,
            ),
          ),
        ),
      ),
    );
  }

  Widget _qualityCard(ImageQuality quality) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber, color: Colors.orange),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  "This photo can't be read reliably",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(quality.message!, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 10),
          Text(
            "Sharpness ${quality.sharpness.toStringAsFixed(0)} · "
            "Brightness ${quality.brightness.toStringAsFixed(0)} · "
            "${quality.width}×${quality.height}",
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text("Take another"),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(DefectAnalysis analysis) {
    if (analysis.isClean) {
      return _banner(
        Icons.check_circle,
        Colors.green,
        "No defects found",
        "The model checked this surface and found nothing wrong with it.",
      );
    }

    if (analysis.isUncertain) {
      return _banner(
        Icons.help_outline,
        Colors.orange,
        "Not sure enough to say",
        "Everything the model saw scored below "
            "${(DefectFinding.confidenceThreshold * 100).round()}%, so "
            "nothing is being acted on. Check the face by eye, and mark "
            "anything you find while tracing it.",
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_impacts.isNotEmpty)
          _banner(
            Icons.summarize,
            Colors.brown,
            "What this costs",
            DefectImpactAnalyser.summarise(_impacts),
          ),
        const SizedBox(height: 8),
        for (var i = 0; i < analysis.actionable.length; i++)
          _findingCard(
            analysis.actionable[i],
            i < _impacts.length ? _impacts[i] : null,
          ),
      ],
    );
  }

  Widget _banner(IconData icon, Color colour, String title, String body) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colour),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _findingCard(DefectFinding finding, DefectImpact? impact) {
    final severity = impact?.severity ?? DefectSeverity.medium;
    final colour = DefectOverlayPainter.colourFor(severity);

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  finding.kind.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colour.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  "${severity.label} severity",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: colour,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _confidenceBar(finding.confidence),
          if (impact != null) ...[
            const SizedBox(height: 12),
            Text(impact.explanation, style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 8),
            Text(
              "Covers ${(impact.faceFraction * 100).toStringAsFixed(1)}% of "
              "the cut face",
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              finding.toDefect().isDisqualifying
                  ? "No board can cross this — it is wood that isn't there."
                  : "A board containing this is still sellable, at a lower "
                      "grade.",
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 6),
            const Text(
              "Trace the log face in the cutting flow to see what it costs "
              "in boards.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  /// The confidence, shown as a bar with the acting threshold marked.
  ///
  /// A bare percentage does not tell anyone whether the app will act on it.
  Widget _confidenceBar(double confidence) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text("Confidence", style: TextStyle(fontSize: 11.5)),
            const Spacer(),
            Text(
              "${(confidence * 100).toStringAsFixed(0)}%",
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: confidence,
                  minHeight: 7,
                  backgroundColor: Colors.grey.shade300,
                  valueColor: AlwaysStoppedAnimation(
                    confidence >= DefectFinding.confidenceThreshold
                        ? Colors.green
                        : Colors.orange,
                  ),
                ),
              ),
              Positioned(
                left: constraints.maxWidth * DefectFinding.confidenceThreshold,
                child: Container(width: 2, height: 7, color: Colors.black54),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          confidence >= DefectFinding.confidenceThreshold
              ? "Above the ${(DefectFinding.confidenceThreshold * 100).round()}% "
                  "line, so cutting plans will route boards around it"
              : "Below the ${(DefectFinding.confidenceThreshold * 100).round()}% "
                  "line, so it is reported but not acted on",
          style: const TextStyle(fontSize: 10.5, color: Colors.grey),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    final quality = _quality;

    return Scaffold(
      backgroundColor: const Color(0xffF5F7FA),
      appBar: AppBar(
        title: const Text("Defect Detection"),
        centerTitle: true,
        actions: [
          if (analysis?.activation != null)
            IconButton(
              tooltip: _showHeatmap ? "Hide heatmap" : "Show heatmap",
              onPressed: () => setState(() => _showHeatmap = !_showHeatmap),
              icon: Icon(
                _showHeatmap ? Icons.blur_on : Icons.blur_off,
              ),
            ),
          if (_file != null)
            IconButton(
              tooltip: "Another photo",
              onPressed: _pick,
              icon: const Icon(Icons.add_a_photo),
            ),
        ],
      ),
      body: _file == null
          ? _emptyState()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _photoCard(),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_error != null)
                  _banner(Icons.error_outline, Colors.red, "Couldn't read it",
                      _error!),
                if (quality != null && !quality.isUsable) _qualityCard(quality),
                if (!_busy &&
                    quality != null &&
                    quality.isUsable &&
                    !_detector.isAvailable) ...[
                  const SizedBox(height: 16),
                  _modelBadge(),
                ],
                if (analysis != null) _resultCard(analysis),
                if (analysis != null &&
                    analysis.actionable.isNotEmpty &&
                    widget.logId != null) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.save_alt),
                      label: const Text("Save these to the log"),
                    ),
                  ),
                ],
                const SizedBox(height: 30),
              ],
            ),
    );
  }
}
