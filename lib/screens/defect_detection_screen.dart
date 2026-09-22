import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database/local_db.dart';
import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../models/sawing_models.dart';
import '../painters/defect_overlay_painter.dart';
import '../services/defect_advisor.dart';
import '../services/defect_impact.dart';
import '../services/defect_scan_controller.dart';
import '../theme/app_theme.dart';
import '../utils/image_quality.dart';
import '../utils/unit_display.dart';
import '../widgets/image_source_sheet.dart';
import '../widgets/scan_widgets.dart';
import '../widgets/ui_kit.dart';
import 'log_report_builder_screen.dart';

/// Inputs for measuring what the confirmed defects cost, off the UI thread.
class _ImpactRequest {
  final LogFaceOutline outline;
  final List<LogDefect> defects;
  final SawingSetup setup;

  const _ImpactRequest(this.outline, this.defects, this.setup);
}

List<DefectImpact> _impactInBackground(_ImpactRequest request) =>
    const DefectImpactAnalyser().analyse(
      outline: request.outline,
      defects: request.defects,
      setup: request.setup,
    );

/// Finds, explains and lets a person correct the defects on a log.
///
/// Three things changed from the first version, each because it was
/// misleading someone:
///
/// - **The count matches the photo.** It used to count only findings above
///   the 60% line while the photo boxed everything, so the two disagreed.
///   Now every finding is shown, counted and numbered; faint ones are marked
///   "check by eye" instead of being silently left out of the total.
/// - **No percentages.** A number like "47%" invited a question nobody in a
///   yard can answer. Certainty is shown as a solid or dashed outline and a
///   plain word.
/// - **A person has the last word.** Any finding can be confirmed or
///   dismissed, and the count, grade and suggestions follow immediately.
class DefectDetectionScreen extends StatefulWidget {
  /// The traced face, when the user arrived from the cutting flow. With it,
  /// the screen can say what a defect costs in board volume.
  final LogFaceOutline? outline;
  final SawingSetup? setup;

  /// The log these findings belong to, when there is one to attach them to.
  final int? logId;

  /// An existing scan to review -- the Log Report builder passes its own, so
  /// decisions made here flow straight into the report.
  final DefectScanController? controller;

  /// Review an existing scan only: no new photo, no report shortcut.
  final bool reviewOnly;

  const DefectDetectionScreen({
    super.key,
    this.outline,
    this.setup,
    this.logId,
    this.controller,
    this.reviewOnly = false,
  });

  @override
  State<DefectDetectionScreen> createState() => _DefectDetectionScreenState();
}

class _DefectDetectionScreenState extends State<DefectDetectionScreen> {
  late DefectScanController _scan = widget.controller ?? DefectScanController();

  bool get _ownsController => widget.controller == null;

  List<DefectImpact> _impacts = const [];

  /// Each impact against the number of the finding it belongs to. Impacts
  /// are only measured for confirmed findings, so list positions differ.
  Map<int, DefectImpact> _impactByIndex = const {};

  Timer? _impactDebounce;
  String _impactKey = "";

  bool _saving = false;

  final _listKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scan.addListener(_onScanChanged);
  }

  @override
  void didUpdateWidget(covariant DefectDetectionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A different scan handed in: follow it, and let go of the old one.
    if (widget.controller != null && widget.controller != _scan) {
      _scan.removeListener(_onScanChanged);
      if (oldWidget.controller == null) _scan.dispose();

      _scan = widget.controller!;
      _scan.addListener(_onScanChanged);
      _impactKey = "";
    }
  }

  @override
  void dispose() {
    _impactDebounce?.cancel();
    _scan.removeListener(_onScanChanged);
    if (_ownsController) _scan.dispose();
    super.dispose();
  }

  void _onScanChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleImpact();
  }

  // --- actions ---------------------------------------------------------------

  Future<void> _pick() async {
    final file = await pickImage(
      context,
      title: "Photograph the log",
      cameraHint: "The cut end or the surface — fill the frame, good light",
      galleryHint: "Use a photo you already took of this log",
    );

    if (file == null || !mounted) return;

    HapticFeedback.lightImpact();
    setState(() {
      _impacts = const [];
      _impactByIndex = const {};
      _impactKey = "";
    });
    await _scan.scan(file);

    if (!mounted || !_scan.hasResult) return;

    HapticFeedback.mediumImpact();
  }

  /// Re-measures the cost of the confirmed defects whenever the set of them
  /// changes. Debounced: tapping through five findings should not start five
  /// sawing searches.
  void _scheduleImpact() {
    final outline = widget.outline;
    final setup = widget.setup;
    final size = _scan.imageSize;

    if (outline == null || setup == null || size == null) return;

    final defects = _scan.confirmedDefects;
    final indices = [
      for (final f in _scan.findings)
        if (f.review == FindingReview.confirmed) f.number - 1,
    ];
    final key = defects.map((d) => "${d.centre}${d.radius}").join("|");

    if (key == _impactKey) return;
    _impactKey = key;

    _impactDebounce?.cancel();

    if (defects.isEmpty) {
      setState(() {
        _impacts = const [];
        _impactByIndex = const {};
      });
      return;
    }

    _impactDebounce = Timer(const Duration(milliseconds: 350), () async {
      // Findings are in photo pixels; the outline is in millimetres. Scale by
      // the ratio of their widths, which is exact because both describe the
      // same face.
      final scale = size.width <= 0 ? 1.0 : outline.bounds.width / size.width;

      final impacts = await compute(
        _impactInBackground,
        _ImpactRequest(
          outline,
          [for (final d in defects) d.scaled(scale)],
          setup,
        ),
      );

      if (!mounted || key != _impactKey) return;
      setState(() {
        _impacts = impacts;
        _impactByIndex = {
          for (var k = 0; k < impacts.length && k < indices.length; k++)
            indices[k]: impacts[k],
        };
      });
    });
  }

  Future<void> _save() async {
    final logId = widget.logId;
    if (logId == null) return;

    final confirmed = [
      for (final f in _scan.findings)
        if (f.review == FindingReview.confirmed) f,
    ];

    if (confirmed.isEmpty) return;

    setState(() => _saving = true);

    try {
      for (final f in confirmed) {
        await LocalDB.saveDefect(
          logId: logId,
          kind: f.finding.kind.name,
          confidence: f.finding.confidence,
          automatic: true,
          centreX: f.finding.region.center.dx,
          centreY: f.finding.region.center.dy,
          radius: f.finding.region.longestSide / 2,
          imagePath: _scan.file?.path,
          severity: _impactByIndex[f.number - 1]?.severity.stored,
        );
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Saved ${confirmed.length} defect"
            "${confirmed.length == 1 ? '' : 's'} to this log.",
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _openReport() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LogReportBuilderScreen(
          initialPhoto: _scan.file,
          scan: _scan,
        ),
      ),
    );
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hasFile = _scan.file != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reviewOnly ? "Review defects" : "Defect Detection"),
        actions: [
          if (hasFile && !widget.reviewOnly)
            IconButton(
              tooltip: "Scan another photo",
              onPressed: _scan.isBusy ? null : _pick,
              icon: const Icon(Icons.add_a_photo_outlined),
            ),
        ],
      ),
      body: hasFile ? _results() : _emptyState(),
      bottomNavigationBar: widget.reviewOnly ? _reviewDoneBar() : null,
    );
  }

  Widget _reviewDoneBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: PrimaryAction(
          label: "Done",
          icon: Icons.check_rounded,
          onPressed: () => Navigator.pop(context),
        ),
      ),
    );
  }

  // --- empty -----------------------------------------------------------------

  Widget _emptyState() {
    final available = _scan.detector.isAvailable;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        FadeSlideIn(
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
            decoration: BoxDecoration(
              gradient: AppTheme.brandGradient,
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge + 4),
              boxShadow: AppTheme.softShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.center_focus_strong_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  "See every defect\nbefore you saw",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Photograph a log and SmartLog finds cracks, holes and "
                  "knots, grades the face, and tells you what to do about "
                  "each one.",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 18),
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _DarkChip(icon: Icons.bolt_rounded, text: "Cracks"),
                    _DarkChip(icon: Icons.circle_outlined, text: "Holes"),
                    _DarkChip(icon: Icons.blur_circular, text: "Knots"),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        FadeSlideIn(
          delay: const Duration(milliseconds: 80),
          child: SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "For the best scan",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                _tip(Icons.crop_free_rounded, "Fill the frame with timber"),
                _tip(Icons.wb_sunny_outlined, "Even daylight, no hard shadow"),
                _tip(
                    Icons.back_hand_outlined, "Hold still — sharp beats close"),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        FadeSlideIn(
          delay: const Duration(milliseconds: 140),
          child: PrimaryAction(
            label: "Take or choose a photo",
            icon: Icons.add_a_photo_rounded,
            onPressed: _pick,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              available ? Icons.memory_rounded : Icons.info_outline_rounded,
              size: 15,
              color: available ? AppTheme.primaryBright : AppTheme.warning,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                available
                    ? "On-device AI · works offline"
                    : "No detection model installed — mark defects by hand "
                        "while tracing the face.",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tip(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          IconBadge(icon: icon, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- results ---------------------------------------------------------------

  Widget _results() {
    final quality = _scan.quality;
    final done = _scan.phase == ScanPhase.done;
    final result = _scan.hasResult && done;
    final findings = _scan.findings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        _photoCard(),
        if (_scan.error != null) ...[
          const SizedBox(height: 16),
          InfoBanner(
            icon: Icons.error_outline_rounded,
            color: AppTheme.error,
            title: "Couldn't read it",
            body: _scan.error,
            action: _retakeButton(),
          ),
        ],
        if (quality != null && !quality.isUsable) ...[
          const SizedBox(height: 16),
          _qualityCard(quality),
        ],
        if (done &&
            quality != null &&
            quality.isUsable &&
            !_scan.detector.isAvailable) ...[
          const SizedBox(height: 16),
          const InfoBanner(
            icon: Icons.info_outline_rounded,
            color: AppTheme.warning,
            title: "No detection model installed",
            body: "You can still mark defects by hand while tracing the log "
                "face in Optimal Cutting or a Log Report.",
          ),
        ],
        if (result) ...[
          const SizedBox(height: 16),
          FadeSlideIn(child: _summaryCard()),
          if (findings.isNotEmpty) ...[
            SectionHeader(
              key: _listKey,
              eyebrow: "Findings",
              title: "What the scan found",
              subtitle: "Tap one to see it on the photo. Correct anything "
                  "the scan got wrong.",
            ),
            for (var i = 0; i < findings.length; i++)
              FadeSlideIn(
                delay: Duration(milliseconds: 40 * i.clamp(0, 6)),
                child: _findingCard(i, findings[i]),
              ),
          ],
          if (_impacts.isNotEmpty) _impactSection(),
          _adviceSection(),
          _actions(),
        ],
      ],
    );
  }

  Widget _retakeButton() {
    return OutlinedButton.icon(
      onPressed: _pick,
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: const Text("Try another photo"),
    );
  }

  Widget _photoCard() {
    final photo = _scan.photo;
    final size = _scan.imageSize;

    final caption = switch (_scan.phase) {
      ScanPhase.preparing => "Checking the photo…",
      ScanPhase.scanning => _scan.passesTotal > 1
          ? "Scanning region ${(_scan.progress * _scan.passesTotal).floor().clamp(1, _scan.passesTotal)} of ${_scan.passesTotal}…"
          : "Scanning…",
      _ => "",
    };

    final aspect =
        size == null ? 4 / 3 : (size.width / size.height).clamp(0.62, 1.8);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
      child: ColoredBox(
        color: const Color(0xFF101512),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photo != null && size != null)
                InteractiveViewer(
                  maxScale: 5,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: DefectOverlayPainter(
                      photo: photo,
                      imageSize: size,
                      marks: _scan.marks(),
                      faceCentre: _scan.faceCentre,
                      faceRadius: _scan.faceRadius,
                    ),
                  ),
                )
              else if (_scan.file != null)
                Image.file(_scan.file!, fit: BoxFit.contain),
              if (_scan.isBusy) ScanSweep(caption: caption),
            ],
          ),
        ),
      ),
    );
  }

  Widget _qualityCard(ImageQuality quality) {
    return InfoBanner(
      icon: Icons.photo_camera_outlined,
      color: AppTheme.warning,
      title: "This photo can't be read reliably",
      body: quality.message,
      action: _retakeButton(),
    );
  }

  Widget _summaryCard() {
    final count = _scan.count;
    final pending = _scan.pendingCount;
    final grade = _scan.grade;
    final breakdown = _scan.breakdown;

    if (count == 0) {
      return SurfaceCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            GradeBadge(grade: grade.grade, size: 58),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "No defects found",
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _scan.dismissedCount > 0
                        ? "Everything the scan marked was dismissed by you."
                        : "The scan checked "
                            "${_scan.analysis?.passes == 1 ? 'this photo' : 'every part of this photo'} "
                            "and found nothing wrong.",
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SurfaceCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: count.toDouble()),
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) => Text(
                            "${value.round()}",
                            style: const TextStyle(
                              fontSize: 44,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -1.5,
                              height: 1,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          count == 1 ? "defect found" : "defects found",
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final entry in breakdown)
                          Pill(
                            text:
                                "${entry.count} ${_plural(entry.label, entry.count)}",
                            color:
                                DefectOverlayPainter.colourForKind(entry.kind),
                            dot: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              GradeBadge(grade: grade.grade, size: 58),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 12),
          Text(
            grade.grade.meaning,
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppTheme.textPrimary,
            ),
          ),
          if (grade.reasons.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              grade.reasons.join("  ·  "),
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ],
          if (pending > 0) ...[
            const SizedBox(height: 12),
            Pill(
              icon: Icons.visibility_outlined,
              text: "$pending to check by eye — the grade may change",
              color: AppTheme.accent,
            ),
          ],
        ],
      ),
    );
  }

  static String _plural(String label, int count) {
    if (count == 1) return label;
    if (label.endsWith("s")) return label;
    return "${label}s";
  }

  Widget _findingCard(int index, ReviewedFinding item) {
    final finding = item.finding;
    final colour = DefectOverlayPainter.colourForKind(finding.kind);
    final dismissed = item.review == FindingReview.dismissed;
    final pending = item.review == FindingReview.pending;
    final selected = _scan.selected == index;

    final zone = item.assessed.zone;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: dismissed ? 0.55 : 1,
        child: SurfaceCard(
          shadow: selected,
          border: BorderSide(
            color: selected ? colour : AppTheme.line,
            width: selected ? 1.6 : 1,
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          onTap: () => _scan.select(index),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: dismissed ? AppTheme.surfaceMuted : colour,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      "${item.number}",
                      style: TextStyle(
                        color: dismissed ? AppTheme.textTertiary : Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      finding.displayLabel,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        decoration:
                            dismissed ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                  if (dismissed)
                    const Pill(text: "Dismissed", color: AppTheme.textTertiary)
                  else if (pending)
                    const Pill(
                      text: "Check by eye",
                      color: AppTheme.accent,
                      icon: Icons.visibility_outlined,
                    )
                  else
                    Pill(
                      text: finding.isConfident ? "Clear" : "Confirmed",
                      color: AppTheme.primaryBright,
                      icon: Icons.check_rounded,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                kindMeaning(finding.kind),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _metaChip(
                      Icons.straighten_rounded, sizeWord(item.assessed.extent)),
                  if (zone != DefectZone.unknown)
                    _metaChip(Icons.adjust_rounded, zone.label),
                  if (_impactByIndex[index] != null && !dismissed)
                    _metaChip(
                      Icons.warning_amber_rounded,
                      "${_impactByIndex[index]!.severity.label} severity",
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // A Wrap, not a Row: on a narrow phone with large text the two
              // buttons must drop to a second line rather than overflow.
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (dismissed)
                    TextButton.icon(
                      onPressed: () => _scan.restore(index),
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: const Text("Undo"),
                    )
                  else ...[
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textSecondary,
                      ),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _scan.dismiss(index);
                      },
                      child: const Text("Not a defect"),
                    ),
                    if (pending)
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _scan.confirm(index);
                        },
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text("Confirm"),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppTheme.textSecondary),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _impactSection() {
    final lost = _impacts.fold<double>(0, (s, i) => s + i.lostCubicFeet);
    final value = _impacts.fold<double>(0, (s, i) => s + i.lostValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(eyebrow: "Impact", title: "What they cost"),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      label: "Boards lost",
                      value: "${lost.toStringAsFixed(2)} ft³",
                      icon: Icons.content_cut_rounded,
                      color: AppTheme.severityHigh,
                    ),
                  ),
                  if (value > 0)
                    Expanded(
                      child: StatTile(
                        label: "Value lost",
                        value: UnitDisplay.rupees(value, decimals: 0),
                        icon: Icons.payments_outlined,
                        color: AppTheme.accent,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                DefectImpactAnalyser.summarise(_impacts),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _adviceSection() {
    final lost = _impacts.fold<double>(0, (s, i) => s + i.lostCubicFeet);
    final value = _impacts.fold<double>(0, (s, i) => s + i.lostValue);

    final advice = _scan.advice(
      lostCubicFeet: lost,
      lostValue: value,
      hasTracedFace: widget.outline != null,
    );

    if (advice.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          eyebrow: "Suggestions",
          title: "What to do about it",
        ),
        for (var i = 0; i < advice.length; i++)
          FadeSlideIn(
            delay: Duration(milliseconds: 50 * i.clamp(0, 5)),
            child: AdviceCard(advice: advice[i]),
          ),
      ],
    );
  }

  Widget _actions() {
    final confirmedCount =
        _scan.findings.where((f) => f.review == FindingReview.confirmed).length;

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        children: [
          if (widget.logId != null && confirmedCount > 0) ...[
            PrimaryAction(
              label: "Save $confirmedCount to this log",
              icon: Icons.save_alt_rounded,
              busy: _saving,
              onPressed: _save,
            ),
            const SizedBox(height: 12),
          ],
          if (!widget.reviewOnly) ...[
            PrimaryAction(
              label: "Build a full Log Report",
              icon: Icons.description_outlined,
              outlined: widget.logId != null && confirmedCount > 0,
              onPressed: _openReport,
            ),
            const SizedBox(height: 12),
            PrimaryAction(
              label: "Scan another photo",
              icon: Icons.add_a_photo_outlined,
              outlined: true,
              onPressed: _pick,
            ),
          ],
        ],
      ),
    );
  }
}

class _DarkChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _DarkChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: const Color(0xFFE8C48F)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
