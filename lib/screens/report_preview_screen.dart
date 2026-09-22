import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/report_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

class ReportPreviewScreen extends StatefulWidget {
  final File pdfFile;

  const ReportPreviewScreen({
    super.key,
    required this.pdfFile,
  });

  @override
  State<ReportPreviewScreen> createState() => _ReportPreviewScreenState();
}

class _ReportPreviewScreenState extends State<ReportPreviewScreen> {
  final _reportService = ReportService();
  bool _busy = false;

  /// The screen used to describe everything as a PDF, so a CSV export
  /// announced itself as a PDF and offered to print itself -- which the PDF
  /// layout engine cannot do with a spreadsheet.
  bool get _isCsv => widget.pdfFile.path.toLowerCase().endsWith(".csv");

  String get _fileName => widget.pdfFile.uri.pathSegments.last;

  String get _sizeLabel {
    try {
      final bytes = widget.pdfFile.lengthSync();
      if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(0)} KB";
      return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    } catch (_) {
      return "";
    }
  }

  Future<void> _print() async {
    setState(() => _busy = true);

    try {
      await _reportService.printReport(widget.pdfFile);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    HapticFeedback.lightImpact();

    try {
      await _reportService.shareReport(widget.pdfFile);
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't share the file. It is saved at $_fileName."),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colour = _isCsv ? AppTheme.success : AppTheme.severityHigh;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isCsv ? "Spreadsheet Ready" : "Report Generated"),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        children: [
          FadeSlideIn(
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1),
                duration: const Duration(milliseconds: 500),
                curve: Curves.elasticOut,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isCsv
                        ? Icons.table_chart_rounded
                        : Icons.picture_as_pdf_rounded,
                    size: 56,
                    color: colour,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            _isCsv
                ? "CSV spreadsheet created."
                : "PDF report generated successfully.",
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isCsv
                ? "One row per log. Share it to yourself and open it in "
                    "Excel or Google Sheets."
                : "Ready to print or send to a buyer.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 24),
          SurfaceCard(
            shadow: false,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                IconBadge(
                  icon: _isCsv
                      ? Icons.description_outlined
                      : Icons.insert_drive_file_outlined,
                  color: colour,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_sizeLabel.isNotEmpty)
                        Text(
                          _sizeLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          PrimaryAction(
            label: "Share / Download",
            icon: Icons.ios_share_rounded,
            busy: _busy,
            onPressed: _share,
          ),
          // Printing is a PDF operation. Offering it for a spreadsheet
          // would be a button that cannot succeed.
          if (!_isCsv) ...[
            const SizedBox(height: 12),
            PrimaryAction(
              label: "Print",
              icon: Icons.print_outlined,
              outlined: true,
              onPressed: _busy ? null : _print,
            ),
          ],
        ],
      ),
    );
  }
}
