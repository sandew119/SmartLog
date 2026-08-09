import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../models/log_defect.dart';
import '../models/sawing_models.dart';
import '../painters/sawing_pattern_painter.dart';
import '../services/diagnostics_service.dart';
import '../services/report_service.dart';
import '../utils/calculator.dart';
import '../widgets/add_to_stack_sheet.dart';
import 'report_preview_screen.dart';

/// Where the plan sits on the photograph it was measured from.
///
/// Null for a log entered by hand: there is nothing to draw on, so the
/// pattern is drawn on a plain background instead. Everything else about the
/// screen is identical either way.
class PatternOverlay {
  final File photo;
  final double mmPerPixel;
  final Offset faceOriginPx;
  final Size imageSize;

  const PatternOverlay({
    required this.photo,
    required this.mmPerPixel,
    required this.faceOriginPx,
    required this.imageSize,
  });
}

class CuttingResultScreen extends StatefulWidget {
  final SawingComparison comparison;
  final PatternOverlay? overlay;

  /// Carried through only so the saved pattern can record the blade it was
  /// planned for -- a yield figure means nothing without the kerf behind it.
  final double kerfMm;

  /// The flaws the plan was calculated against, stored alongside it so a
  /// board routed around rot can be justified later.
  final List<LogDefect> defects;

  const CuttingResultScreen({
    super.key,
    required this.comparison,
    this.overlay,
    this.kerfMm = 0,
    this.defects = const [],
  });

  @override
  State<CuttingResultScreen> createState() => _CuttingResultScreenState();
}

class _CuttingResultScreenState extends State<CuttingResultScreen> {
  late SawingStrategy _selected;

  ui.Image? _photo;
  bool _cutsExpanded = false;
  bool _showNumbers = true;
  bool _buildingReport = false;

  @override
  void initState() {
    super.initState();

    // Open on whichever strategy yields more, but as a preselection the user
    // can overrule: a mill with no resaw simply cannot cut a cant, and no
    // amount of arithmetic here knows that.
    _selected = widget.comparison.best?.strategy ?? SawingStrategy.cant;

    _loadPhoto();
  }

  /// Resolves the photo through Flutter's own image pipeline.
  ///
  /// Deliberately the same path the tracing screen used to size the image:
  /// decoding it a second way risks a different EXIF interpretation, which
  /// would place every board a quarter turn out from the log underneath it.
  void _loadPhoto() {
    final overlay = widget.overlay;
    if (overlay == null) return;

    final stream = FileImage(overlay.photo).resolve(const ImageConfiguration());

    late final ImageStreamListener listener;

    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;
        setState(() => _photo = info.image);
      },
      onError: (_, __) {
        stream.removeListener(listener);
      },
    );

    stream.addListener(listener);
  }

  SawPlan? get _plan => switch (_selected) {
        SawingStrategy.cant => widget.comparison.cant,
        SawingStrategy.live => widget.comparison.live,
      };

  // --- pattern ------------------------------------------------------------

  /// Drawing geometry for the plain-background case, so the painter has one
  /// code path whether or not there is a photograph.
  ({double mmPerPixel, Offset origin, Size size}) _syntheticFrame(
      SawPlan plan) {
    final bounds = plan.outline.bounds;
    final pad = math.max(bounds.width, bounds.height) * 0.08 + 1;

    return (
      mmPerPixel: 1,
      origin: Offset(pad - bounds.left, pad - bounds.top),
      size: Size(bounds.width + pad * 2, bounds.height + pad * 2),
    );
  }

  Widget _buildPattern(SawPlan plan) {
    final overlay = widget.overlay;

    final double mmPerPixel;
    final Offset origin;
    final Size imageSize;

    if (overlay != null) {
      mmPerPixel = overlay.mmPerPixel;
      origin = overlay.faceOriginPx;
      imageSize = overlay.imageSize;
    } else {
      final frame = _syntheticFrame(plan);
      mmPerPixel = frame.mmPerPixel;
      origin = frame.origin;
      imageSize = frame.size;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: imageSize.height <= 0
            ? 1
            : (imageSize.width / imageSize.height).clamp(0.5, 2.0),
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: CustomPaint(
            size: Size.infinite,
            painter: SawingPatternPainter(
              plan: plan,
              mmPerPixel: mmPerPixel,
              faceOriginPx: origin,
              imageSize: imageSize,
              photo: _photo,
              showCutNumbers: _showNumbers,
            ),
          ),
        ),
      ),
    );
  }

  // --- comparison ---------------------------------------------------------

  Widget _strategyCard(SawPlan plan) {
    final selected = plan.strategy == _selected;
    final best = widget.comparison.best?.strategy == plan.strategy;

    // A Material rather than a decorated Container: ink splashes are painted
    // on the nearest Material ancestor, so a card that paints its own
    // background over that ancestor swallows its own tap feedback.
    return Expanded(
      child: Material(
        color: selected ? const Color(0xFFEFF7EF) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _selected = plan.strategy),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? Colors.green : Colors.grey.shade300,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        plan.strategy.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (best)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          "Most timber",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "${plan.boardCount} boards",
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  "${plan.boardVolumeCubicFeet.toStringAsFixed(2)} ft³  ·  "
                  "${plan.yieldPercent.toStringAsFixed(0)}% yield",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 6),
                Text(
                  plan.strategy.explanation,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _comparison() {
    final plans = widget.comparison.plans;
    if (plans.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: IntrinsicHeight(
        // The two cards carry different amounts of text, and a pair of
        // side-by-side options that don't line up at the bottom reads as a
        // mistake. Stretching alone can't do it inside a scroll view --
        // there is no bounded height to stretch to -- so the taller card
        // has to be measured first.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _strategyCard(plans.first),
            const SizedBox(width: 12),
            _strategyCard(plans.last),
          ],
        ),
      ),
    );
  }

  // --- stats --------------------------------------------------------------

  Widget _stat(String label, String value, IconData icon, Color colour) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colour, size: 20),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _statGrid(SawPlan plan) {
    // Kerf and edging are the two places timber physically disappears; a
    // single "waste" number hides which one the mill could actually act on.
    final kerfCubicFeet = _areaToCubicFeet(plan.kerfAreaMm2, plan.logLengthMm);
    final edgingCubicFeet =
        _areaToCubicFeet(plan.edgingAreaMm2, plan.logLengthMm);

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 0.95,
      children: [
        _stat(
          "Yield",
          "${plan.yieldPercent.toStringAsFixed(1)}%",
          Icons.pie_chart,
          Colors.green,
        ),
        _stat(
          "Sawn timber",
          "${plan.boardVolumeCubicFeet.toStringAsFixed(2)} ft³",
          Icons.dashboard,
          Colors.blue,
        ),
        _stat(
          "Log volume",
          "${plan.logVolumeCubicFeet.toStringAsFixed(2)} ft³",
          Icons.forest,
          Colors.teal,
        ),
        _stat(
          "Sawdust",
          "${kerfCubicFeet.toStringAsFixed(2)} ft³",
          Icons.content_cut,
          Colors.brown,
        ),
        _stat(
          "Edgings & slabs",
          "${edgingCubicFeet.toStringAsFixed(2)} ft³",
          Icons.delete_outline,
          Colors.orange,
        ),
        _stat(
          "Saw passes",
          "${plan.sawPasses}",
          Icons.repeat,
          Colors.purple,
        ),
      ],
    );
  }

  static double _areaToCubicFeet(double areaMm2, double lengthMm) =>
      (areaMm2 * lengthMm) / (304.8 * 304.8 * 304.8);

  Widget _valueBanner(SawPlan plan) {
    if (plan.pricePerCubicFoot <= 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.payments_outlined, color: Colors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Rs. ${plan.value.toStringAsFixed(2)}",
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
                Text(
                  "${plan.boardVolumeCubicFeet.toStringAsFixed(2)} ft³ at "
                  "Rs. ${plan.pricePerCubicFoot.toStringAsFixed(0)} per ft³",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- board sizes --------------------------------------------------------

  Widget _boardSizes(SawPlan plan) {
    if (plan.boards.isEmpty) return const SizedBox.shrink();

    // Group by finished size so the yard gets a picking list, not 40 rows.
    final counts = <String, int>{};

    for (final board in plan.boards) {
      final key = "${board.width.round()} × ${board.thickness.round()} mm";
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "What comes off this log",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            "Length ${(plan.logLengthMm / 304.8).toStringAsFixed(1)} ft "
            "on every piece",
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(entry.key)),
                  Text(
                    "× ${entry.value}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // --- cut list -----------------------------------------------------------

  Widget _cutList(SawPlan plan) {
    if (plan.cuts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      // A Material, not a decorated Container: the tiles inside paint their
      // ink on the nearest Material ancestor, and a white BoxDecoration in
      // between would hide every splash they draw.
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade300),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _cutsExpanded,
            onExpansionChanged: (v) => setState(() => _cutsExpanded = v),
            leading:
                const Icon(Icons.format_list_numbered, color: Colors.brown),
            title: const Text(
              "Cut list",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            subtitle: Text(
              "${plan.cuts.length} passes, in order",
              style: const TextStyle(fontSize: 12),
            ),
            children: [
              for (final cut in plan.cuts)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 13,
                    backgroundColor: cut.definesCant
                        ? const Color(0xFF1565C0)
                        : Colors.grey.shade400,
                    child: Text(
                      "${cut.order}",
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    cut.description,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: Text(
                    "${cut.setback.toStringAsFixed(0)} mm",
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Text(
                  "Setbacks are measured from the same reference face, in the "
                  "order listed.",
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- actions ------------------------------------------------------------

  Future<void> _addToStack(SawPlan plan) async {
    final diameterInches = plan.outline.equivalentCircleDiameter / 25.4;
    final lengthFeet = plan.logLengthMm / 304.8;

    final stackId = await showAddToStackSheet(
      context,
      diameterInches: diameterInches,
      lengthFeet: lengthFeet,
      volumeCubicFeet: Calculator.calculateVolume(
        diameter: diameterInches,
        lengthFeet: lengthFeet,
      ),
    );

    if (!mounted) return;

    if (stackId != null) {
      // The log now exists, so the plan finally has something to belong to.
      // Until this point the pattern was only ever on screen: closing the
      // screen used to throw away the whole calculation, which made it
      // impossible to reopen, export, or defend a price afterwards.
      await _persistPlan(plan);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Added to stack, with its cutting plan.")),
      );
    }
  }

  /// Stores the plan and the defects it was calculated against.
  ///
  /// Attached to the most recently saved log, which is the one the sheet just
  /// created. One pattern per log: recalculating replaces the old answer
  /// rather than leaving two rival plans nobody can choose between.
  Future<void> _persistPlan(SawPlan plan) async {
    try {
      final logs = await LocalDB.getAllLogs();
      if (logs.isEmpty) return;

      final logId = logs.last["id"] as int;

      final wasteCubicFeet =
          (plan.logVolumeCubicFeet - plan.boardVolumeCubicFeet)
              .clamp(0, double.infinity)
              .toDouble();

      await LocalDB.saveCuttingPattern(
        logId: logId,
        strategy: plan.strategy.name,
        boardWidthMm: plan.boards.isEmpty ? null : plan.boards.first.width,
        boardThicknessMm: plan.boards.isEmpty ? 0 : plan.boards.first.thickness,
        bladeThicknessMm: widget.kerfMm,
        boardCount: plan.boardCount,
        yieldPercent: plan.yieldPercent,
        boardVolumeCubicFeet: plan.boardVolumeCubicFeet,
        wasteVolumeCubicFeet: wasteCubicFeet,
        sawPasses: plan.sawPasses,
        pricePerCubicFoot: plan.pricePerCubicFoot,
      );

      for (final defect in widget.defects) {
        await LocalDB.saveDefect(
          logId: logId,
          kind: defect.kind.name,
          confidence: defect.confidence,
          automatic: defect.automatic,
          centreX: defect.centre.dx,
          centreY: defect.centre.dy,
          radius: defect.radius,
          imagePath: widget.overlay?.photo.path,
        );
      }
    } catch (error) {
      await DiagnosticsService.instance.recordError(
        module: DiagnosticsService.moduleCutting,
        error: error,
      );
    }
  }

  Future<void> _cutSheet(SawPlan plan) async {
    setState(() => _buildingReport = true);

    try {
      final file = await ReportService().generateCuttingReport(
        plan: plan,
        capturedImage: widget.overlay?.photo,
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ReportPreviewScreen(pdfFile: file)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't build the cut sheet.")),
      );
    } finally {
      if (mounted) setState(() => _buildingReport = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;

    return Scaffold(
      backgroundColor: const Color(0xffF5F7FA),
      appBar: AppBar(
        centerTitle: true,
        title: const Text("Cutting Plan"),
        actions: [
          if (plan != null && plan.boards.isNotEmpty)
            IconButton(
              tooltip:
                  _showNumbers ? "Hide board numbers" : "Show board numbers",
              onPressed: () => setState(() => _showNumbers = !_showNumbers),
              icon: Icon(_showNumbers ? Icons.tag : Icons.tag_outlined),
            ),
        ],
      ),
      body: plan == null ? _buildEmpty() : _buildPlan(plan),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 56, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              "No board of that size fits this log",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              "Go back and try a smaller board, a thinner blade, or switch to "
              "fixed-thickness so the app can pick the widths.",
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlan(SawPlan plan) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _comparison(),
        _buildPattern(plan),
        const SizedBox(height: 8),
        Text(
          widget.overlay == null
              ? "The plan, drawn on the outline of the log."
              : "The plan, drawn on your photo inside the boundary you traced.",
          style: const TextStyle(fontSize: 11, color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _statGrid(plan),
        _valueBanner(plan),
        _boardSizes(plan),
        _cutList(plan),
        const SizedBox(height: 24),
        SizedBox(
          height: 55,
          child: ElevatedButton.icon(
            onPressed: () => _addToStack(plan),
            icon: const Icon(Icons.layers),
            label: const Text("Add to Stack"),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 50,
          child: OutlinedButton.icon(
            onPressed: _buildingReport ? null : () => _cutSheet(plan),
            icon: _buildingReport
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf),
            label: const Text("Cut sheet for the sawyer (PDF)"),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () =>
              Navigator.popUntil(context, (route) => route.isFirst),
          icon: const Icon(Icons.home),
          label: const Text("Back to Home"),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}
