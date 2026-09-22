import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../database/local_db.dart';
import '../models/log_report.dart';
import '../models/sawing_models.dart';
import '../services/defect_advisor.dart';
import '../services/defect_impact.dart';
import '../services/diagnostics_service.dart';
import '../services/log_report_pdf.dart';
import '../services/report_service.dart';
import '../theme/app_theme.dart';
import '../utils/timber_volume.dart';
import '../utils/unit_display.dart';
import '../widgets/scan_widgets.dart';
import '../widgets/ui_kit.dart';
import 'report_preview_screen.dart';

/// A finished Log Passport: everything about one log, on one screen, ready
/// to export.
///
/// Reads straight off [LogReportData] and computes nothing, so the screen
/// and the PDF it exports can never disagree.
class LogReportScreen extends StatefulWidget {
  final LogReportData data;

  /// The saved log this report describes, when there is one -- recorded
  /// against the export so it can be found from the log later.
  final int? logId;

  const LogReportScreen({super.key, required this.data, this.logId});

  @override
  State<LogReportScreen> createState() => _LogReportScreenState();
}

class _LogReportScreenState extends State<LogReportScreen> {
  static final _date = DateFormat("d MMM yyyy · h:mm a");

  File? _pdf;
  bool _exporting = false;

  LogReportData get _data => widget.data;

  /// Builds the PDF once and reuses it for every export action.
  Future<File?> _ensurePdf() async {
    if (_pdf != null && _pdf!.existsSync()) return _pdf;

    setState(() => _exporting = true);

    try {
      final file = await LogReportPdf.write(_data);

      await LocalDB.saveReport(
        logId: widget.logId,
        format: "pdf",
        filePath: file.path,
        totalVolumeCubicFeet: _data.volume.cubicFeetDecimal,
        totalCost: _data.logValue,
      );

      _pdf = file;
      return file;
    } catch (error) {
      await DiagnosticsService.instance.recordError(
        module: DiagnosticsService.moduleReport,
        error: error,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't build the PDF. Try again.")),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openPdf() async {
    final file = await _ensurePdf();
    if (file == null || !mounted) return;

    HapticFeedback.mediumImpact();

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReportPreviewScreen(pdfFile: file)),
    );
  }

  Future<void> _share() async {
    final file = await _ensurePdf();
    if (file == null) return;

    try {
      await ReportService().shareReport(file);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open the share sheet.")),
      );
    }
  }

  Future<void> _print() async {
    final file = await _ensurePdf();
    if (file == null) return;

    try {
      await ReportService().printReport(file);
    } catch (_) {}
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Log Passport"),
        actions: [
          IconButton(
            tooltip: "Print",
            onPressed: _exporting ? null : _print,
            icon: const Icon(Icons.print_outlined),
          ),
          IconButton(
            tooltip: "Share PDF",
            onPressed: _exporting ? null : _share,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          FadeSlideIn(child: _hero()),
          const SizedBox(height: 12),
          FadeSlideIn(
            delay: const Duration(milliseconds: 60),
            child: _keyFigures(),
          ),
          _measurementsSection(),
          _defectsSection(),
          _impactSection(),
          _cuttingSection(),
          _adviceSection(),
          if (_data.notes != null && _data.notes!.trim().isNotEmpty) ...[
            const SectionHeader(eyebrow: "Section 6", title: "Notes"),
            SurfaceCard(
              child: Text(
                _data.notes!.trim(),
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ),
          ],
          const SizedBox(height: 22),
          const Text(
            "The SmartLog grade is an indicative assessment of the visible "
            "face, not a certified grading.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppTheme.textTertiary),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: AppTheme.background,
            border: Border(top: BorderSide(color: AppTheme.line)),
          ),
          child: PrimaryAction(
            label: "Export PDF",
            icon: Icons.picture_as_pdf_rounded,
            busy: _exporting,
            onPressed: _openPdf,
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    final grade = _data.grade.grade;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge + 4),
        boxShadow: AppTheme.softShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "LOG PASSPORT",
                  style: TextStyle(
                    color: Color(0xFFE8C48F),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _data.reference,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (_data.species != null) _data.species!,
                    _date.format(_data.createdAt),
                  ].join("  ·  "),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  grade.meaning,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GradeBadge(grade: grade, size: 64, onDark: true),
        ],
      ),
    );
  }

  Widget _keyFigures() {
    final bookMethod = _data.volumeMethod == VolumeMethod.referenceTable;

    final volume = bookMethod
        ? "${_data.volume.adi} adi ${_data.volume.angal} angal"
        : "${_data.volume.cubicFeetDecimal.toStringAsFixed(2)} ft³";

    // Two by two: four figures side by side leave the volume -- the longest
    // and the one that matters most -- too narrow to read at phone width.
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: "Volume",
                  value: volume,
                  caption: bookMethod
                      ? "${_data.volume.cubicFeetDecimal.toStringAsFixed(2)} ft³"
                      : "cylinder",
                  icon: Icons.view_in_ar_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: "Girth",
                  value: "${_data.girthInches.toStringAsFixed(1)} in",
                  caption:
                      "${(_data.girthInches * 2.54).toStringAsFixed(0)} cm",
                  icon: Icons.radio_button_unchecked_rounded,
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(),
          ),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: "Length",
                  value: "${_data.lengthFeet.toStringAsFixed(1)} ft",
                  caption:
                      "${(_data.lengthFeet * 0.3048).toStringAsFixed(2)} m",
                  icon: Icons.straighten_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: "Defects",
                  value: _data.scanned || _data.defects.isNotEmpty
                      ? "${_data.defects.length}"
                      : "—",
                  caption: _data.scanned ? "on the face" : "not scanned",
                  icon: Icons.report_gmailerrorred_rounded,
                  color: _data.defects.isEmpty
                      ? AppTheme.primaryBright
                      : AppTheme.severityMedium,
                ),
              ),
            ],
          ),
          if (_data.ratePerCubicFoot > 0) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(),
            ),
            Row(
              children: [
                const Icon(
                  Icons.payments_outlined,
                  size: 18,
                  color: AppTheme.accent,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Log value",
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                Text(
                  UnitDisplay.rupees(_data.logValue, decimals: 0),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // --- 1. measurements -------------------------------------------------------

  Widget _measurementsSection() {
    final bookMethod = _data.volumeMethod == VolumeMethod.referenceTable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(eyebrow: "Section 1", title: "Measurements"),
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            children: [
              DetailRow(
                label: "Girth",
                value: "${_data.girthInches.toStringAsFixed(1)} in",
                note: "${(_data.girthInches * 2.54).toStringAsFixed(1)} cm",
              ),
              DetailRow(
                label: "Mean diameter",
                value: "${_data.diameterInches.toStringAsFixed(1)} in",
                note: "${(_data.diameterInches * 2.54).toStringAsFixed(1)} cm",
              ),
              if (_data.hasFaceShape)
                DetailRow(
                  label: "Cut face",
                  value: "${_data.faceMajorInches!.toStringAsFixed(1)} × "
                      "${_data.faceMinorInches!.toStringAsFixed(1)} in",
                  note: "widest × narrowest, traced",
                ),
              DetailRow(
                label: "Length",
                value: "${_data.lengthFeet.toStringAsFixed(2)} ft",
                note: "${(_data.lengthFeet * 0.3048).toStringAsFixed(2)} m",
              ),
              if (_data.deductionInches > 0)
                DetailRow(
                  label: "Girth allowance",
                  value: "−${_data.deductionInches.toStringAsFixed(1)} in",
                  note: "taken off before the volume",
                ),
              DetailRow(
                label: bookMethod ? "Volume (ready-reckoner)" : "Volume",
                value: bookMethod
                    ? "${_data.volume.adi} adi ${_data.volume.angal} angal"
                    : "${_data.volume.cubicFeetDecimal.toStringAsFixed(3)} ft³",
                note: bookMethod
                    ? "${_data.volume.cubicFeetDecimal.toStringAsFixed(3)} ft³"
                    : null,
                emphasise: true,
              ),
              DetailRow(
                label: "Geometric volume",
                value: "${_data.cylinderCubicFeet.toStringAsFixed(3)} ft³",
                note: "cylinder, no allowance",
              ),
              if (_data.ratePerCubicFoot > 0) ...[
                DetailRow(
                  label: "Rate",
                  value: "${UnitDisplay.rupees(_data.ratePerCubicFoot)} / ft³",
                ),
                DetailRow(
                  label: "Log value",
                  value: UnitDisplay.rupees(_data.logValue),
                  emphasise: true,
                ),
              ],
              DetailRow(label: "Measured by", value: _data.measurementSource),
            ],
          ),
        ),
      ],
    );
  }

  // --- 2. defects ------------------------------------------------------------

  Widget _defectsSection() {
    final children = <Widget>[
      const SectionHeader(eyebrow: "Section 2", title: "Defects"),
    ];

    if (!_data.scanned && _data.defects.isEmpty) {
      children.add(
        const InfoBanner(
          icon: Icons.photo_camera_outlined,
          color: AppTheme.textSecondary,
          title: "Not scanned",
          body: "No defect scan was made for this log.",
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    if (_data.defectImage != null) {
      children.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge - 4),
          child: ColoredBox(
            color: const Color(0xFF101512),
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.memory(_data.defectImage!, fit: BoxFit.contain),
            ),
          ),
        ),
      );
      children.add(const SizedBox(height: 12));
    }

    if (_data.defects.isEmpty) {
      children.add(
        InfoBanner(
          icon: Icons.verified_rounded,
          color: AppTheme.success,
          title: "No defects found",
          body: _data.dismissedCount > 0
              ? "${_data.dismissedCount} mark"
                  "${_data.dismissedCount == 1 ? ' was' : 's were'} checked "
                  "and dismissed."
              : "The scan found nothing wrong with this face.",
        ),
      );
    } else {
      children.add(
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in _data.defectBreakdown)
                    Pill(
                      text: "${entry.count} ${entry.label}"
                          "${entry.count == 1 || entry.label.endsWith('s') ? '' : 's'}",
                      color: AppTheme.severityMedium,
                      dot: true,
                    ),
                ],
              ),
              if (_data.grade.reasons.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _data.grade.reasons.join("  ·  "),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Divider(),
              for (var i = 0; i < _data.defects.length; i++)
                _defectRow(i + 1, _data.defects[i]),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _defectRow(int number, AssessedDefect defect) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              shape: BoxShape.circle,
            ),
            child: Text(
              "$number",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  defect.label,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [
                    sizeWord(defect.extent),
                    if (defect.zone != DefectZone.unknown) defect.zone.label,
                  ].join(" · "),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Pill(
            text: defect.manual
                ? "By hand"
                : (defect.confirmed ? "Confirmed" : "Check by eye"),
            color: defect.confirmed || defect.manual
                ? AppTheme.primaryBright
                : AppTheme.accent,
          ),
        ],
      ),
    );
  }

  // --- 3. impact -------------------------------------------------------------

  Widget _impactSection() {
    final children = <Widget>[
      const SectionHeader(eyebrow: "Section 3", title: "Impact of defects"),
    ];

    if (!_data.hasImpact) {
      children.add(
        InfoBanner(
          icon: Icons.info_outline_rounded,
          color: AppTheme.textSecondary,
          title: "Not measured",
          body: _data.plan == null
              ? "Plan the cut to measure what the defects cost in boards."
              : "The face wasn't traced, so the defects couldn't be placed "
                  "on it.",
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    final rate = _data.setup?.pricePerCubicFoot ?? 0;
    final lost = _data.lostCubicFeet;

    children.add(
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: "If sound",
                    value:
                        "${_data.soundYieldCubicFeet!.toStringAsFixed(2)} ft³",
                    caption: "of boards",
                    icon: Icons.eco_outlined,
                  ),
                ),
                Expanded(
                  child: StatTile(
                    label: "As it is",
                    value:
                        "${_data.actualYieldCubicFeet!.toStringAsFixed(2)} ft³",
                    caption: "of boards",
                    icon: Icons.forest_outlined,
                  ),
                ),
                Expanded(
                  child: StatTile(
                    label: "Lost",
                    value: "${lost.toStringAsFixed(2)} ft³",
                    caption: rate > 0
                        ? UnitDisplay.rupees(_data.lostValue, decimals: 0)
                        : "to defects",
                    icon: Icons.trending_down_rounded,
                    color: lost > 0.005
                        ? AppTheme.severityHigh
                        : AppTheme.primaryBright,
                  ),
                ),
              ],
            ),
            if (_data.impacts.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Divider(),
              for (final impact in _data.impacts) _impactRow(impact, rate),
            ],
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _impactRow(DefectImpact impact, double rate) {
    final colour = switch (impact.severity) {
      DefectSeverity.high => AppTheme.severityHigh,
      DefectSeverity.medium => AppTheme.severityMedium,
      DefectSeverity.low => AppTheme.severityLow,
    };

    final name = impact.defect.kind.name;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "${name[0].toUpperCase()}${name.substring(1)} · "
              "${impact.severity.label} severity",
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            rate > 0
                ? "${impact.lostCubicFeet.toStringAsFixed(2)} ft³ · "
                    "${UnitDisplay.rupees(impact.lostValue, decimals: 0)}"
                : "${impact.lostCubicFeet.toStringAsFixed(2)} ft³",
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // --- 4. cutting ------------------------------------------------------------

  Widget _cuttingSection() {
    final plan = _data.plan;

    final children = <Widget>[
      const SectionHeader(eyebrow: "Section 4", title: "Cutting pattern"),
    ];

    if (plan == null) {
      children.add(
        const InfoBanner(
          icon: Icons.content_cut_rounded,
          color: AppTheme.textSecondary,
          title: "No cutting plan",
          body: "This report was made without planning the cut.",
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    final sizes = <String, int>{};
    for (final board in plan.boards) {
      final key = "${board.width.round()} × ${board.thickness.round()} mm";
      sizes[key] = (sizes[key] ?? 0) + 1;
    }

    final entries = sizes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (_data.patternImage != null) {
      children.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge - 4),
          child: ColoredBox(
            color: Colors.black,
            child: InteractiveViewer(
              maxScale: 6,
              child: Image.memory(_data.patternImage!, fit: BoxFit.contain),
            ),
          ),
        ),
      );
      children.add(const SizedBox(height: 12));
    }

    children.add(
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconBadge(icon: Icons.auto_awesome_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.strategy.label,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        _data.planAvoidsDefects
                            ? "Recommended · boards avoid the defects"
                            : "Recommended · most timber",
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: "Boards",
                    value: "${plan.boardCount}",
                  ),
                ),
                Expanded(
                  child: StatTile(
                    label: "Sawn timber",
                    value:
                        "${plan.boardVolumeCubicFeet.toStringAsFixed(2)} ft³",
                  ),
                ),
                Expanded(
                  child: StatTile(
                    label: "Yield",
                    value: "${plan.yieldPercent.toStringAsFixed(0)}%",
                  ),
                ),
              ],
            ),
            if (plan.pricePerCubicFoot > 0) ...[
              const SizedBox(height: 12),
              DetailRow(
                label: "Sawn value",
                value: UnitDisplay.rupees(plan.value),
                emphasise: true,
              ),
            ],
            if (entries.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                "What comes off this log",
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.crop_16_9_rounded,
                        size: 16,
                        color: AppTheme.primaryBright,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(entry.key)),
                      Text(
                        "× ${entry.value}",
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
            ],
            if (plan.cuts.isNotEmpty)
              Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    "Cut list · ${plan.cuts.length} passes",
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  children: [
                    for (final cut in plan.cuts)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Text(
                                "${cut.order}",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.primaryBright,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                cut.description,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                            Text(
                              "${cut.setback.toStringAsFixed(0)} mm",
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // --- 5. advice -------------------------------------------------------------

  Widget _adviceSection() {
    if (_data.advice.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(eyebrow: "Section 5", title: "Suggestions"),
        for (final advice in _data.advice) AdviceCard(advice: advice),
      ],
    );
  }
}
