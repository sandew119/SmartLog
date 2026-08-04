import 'dart:io';
import 'package:flutter/material.dart';

class ReportPreviewScreen extends StatelessWidget {
  final File pdfFile;

  const ReportPreviewScreen({
    super.key,
    required this.pdfFile,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Report Generated"),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "PDF successfully generated.\n\nLocation:\n${pdfFile.path}",
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}