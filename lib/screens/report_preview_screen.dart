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

  Future<void> _print() async {
    setState(() => _busy = true);
    await _reportService.printReport(widget.pdfFile);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    await _reportService.shareReport(widget.pdfFile);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Report Generated"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            const Icon(
              Icons.picture_as_pdf,
              size: 90,
              color: Colors.red,
            ),
            const SizedBox(height: 20),
            const Text(
              "PDF report generated successfully.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.pdfFile.path,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _share,
                icon: const Icon(Icons.share),
                label: const Text("Share / Download"),
              ),
            ),
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
        ),
      ),
    );
  }
}
