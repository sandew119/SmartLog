import 'dart:io';

import 'package:flutter/material.dart';

import '../services/report_service.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Text(_isCsv ? "Spreadsheet Ready" : "Report Generated"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            Icon(
              _isCsv ? Icons.table_chart : Icons.picture_as_pdf,
              size: 90,
              color: _isCsv ? Colors.green : Colors.red,
            ),
            const SizedBox(height: 20),
            Text(
              _isCsv
                  ? "CSV spreadsheet created."
                  : "PDF report generated successfully.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isCsv
                  ? "One row per log. Share it to yourself and open it in "
                      "Excel or Google Sheets."
                  : "Ready to print or send to a buyer.",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Text(
              widget.pdfFile.path,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
            const SizedBox(height: 34),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _share,
                icon: const Icon(Icons.share),
                label: const Text("Share / Download"),
              ),
            ),
            // Printing is a PDF operation. Offering it for a spreadsheet
            // would be a button that cannot succeed.
            if (!_isCsv) ...[
              const SizedBox(height: 15),
              SizedBox(
                width: double.infinity,
                height: 55,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _print,
                  icon: const Icon(Icons.print),
                  label: const Text("Print"),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
