import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../models/log_model.dart';
import '../models/stack_model.dart';
import '../screens/report_preview_screen.dart';
import '../services/report_service.dart';

/// The export formats the specification requires.
///
/// PDF for a document to hand over or print; CSV so the same figures can be
/// opened in Excel and worked with, which is what a merchant reconciling a
/// month of sales actually needs.
enum ReportFormat { pdf, csv }

/// Generates and opens a PDF report for [stack], or for a single
/// [standaloneLog] treated as a synthetic one-log "stack". Exactly one of
/// the two must be provided.
Future<void> generateAndOpenReport(
  BuildContext context, {
  StackModel? stack,
  LogModel? standaloneLog,
  ReportFormat format = ReportFormat.pdf,
}) async {
  assert(
    (stack == null) != (standaloneLog == null),
    "Pass exactly one of stack or standaloneLog",
  );

  final StackModel resolvedStack;

  if (standaloneLog != null) {
    resolvedStack = StackModel(
      id: 0,
      name: "Single Log",
      totalVolume: standaloneLog.volume,
      totalCost: standaloneLog.cost,
      createdAt: standaloneLog.createdAt,
      logs: [standaloneLog],
    );
  } else {
    final logRows = await LocalDB.getLogsForStack(stack!.id);
    final logs = logRows.map(LogModel.fromMap).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    resolvedStack = StackModel(
      id: stack.id,
      name: stack.name,
      totalVolume: stack.totalVolume,
      totalCost: stack.totalCost,
      createdAt: stack.createdAt,
      logs: logs,
      customerName: stack.customerName,
      remarks: stack.remarks,
    );
  }

  if (!context.mounted) return;

  final service = ReportService();
  final company = await _companyFromProfile();
  final generatedAt = DateTime.now();

  final file = switch (format) {
    ReportFormat.pdf => await service.generateStackReport(
        stack: resolvedStack,
        company: company,
        generatedAt: generatedAt,
      ),
    ReportFormat.csv => await service.generateStackCsv(
        stack: resolvedStack,
        company: company,
        generatedAt: generatedAt,
      ),
  };

  // The report history. Kept so a document already handed to a buyer can be
  // found and re-sent, rather than regenerated from data that may since have
  // changed underneath it.
  await LocalDB.saveReport(
    stackId: standaloneLog == null ? resolvedStack.id : null,
    logId: standaloneLog?.id,
    format: format.name,
    filePath: file.path,
    totalVolumeCubicFeet: resolvedStack.totalVolume,
    totalCost: resolvedStack.totalCost,
  );

  if (!context.mounted) return;

  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ReportPreviewScreen(pdfFile: file)),
  );
}

/// Reads the seller's company off their profile. Never prompts.
///
/// Generating a report used to open a company-name dialog every single time,
/// which is a question the user has already answered on their profile. If
/// they haven't filled it in, the report simply omits the line rather than
/// standing between them and their PDF.
///
/// Returns "" when signed out, offline, or when the field was never set.
Future<String> _companyFromProfile() async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return "";

    final doc = await FirebaseFirestore.instance
        .collection("users")
        .doc(user.uid)
        .get();

    return (doc.data()?["company"] as String? ?? "").trim();
  } catch (_) {
    // A report that prints without a letterhead beats no report at all.
    return "";
  }
}
