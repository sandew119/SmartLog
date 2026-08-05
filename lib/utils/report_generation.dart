import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../models/log_model.dart';
import '../models/stack_model.dart';
import '../screens/report_preview_screen.dart';
import '../services/report_service.dart';

/// Generates and opens a PDF report for [stack], or for a single
/// [standaloneLog] treated as a synthetic one-log "stack". Exactly one of
/// the two must be provided.
Future<void> generateAndOpenReport(
  BuildContext context, {
  StackModel? stack,
  LogModel? standaloneLog,
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
    );
  }

  if (!context.mounted) return;

  final company = await _resolveCompanyName(context);
  if (company == null || !context.mounted) return;

  final file = await ReportService().generateStackReport(
    stack: resolvedStack,
    company: company,
    generatedAt: DateTime.now(),
  );

  if (!context.mounted) return;

  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ReportPreviewScreen(pdfFile: file)),
  );
}

/// Shows an editable, Firestore-prefilled company-name dialog. Returns the
/// confirmed name, or null if the user cancelled. Also self-heals the
/// long-standing gap where Google sign-in always writes an empty company
/// name, by saving any edit back to the user's Firestore doc.
Future<String?> _resolveCompanyName(BuildContext context) async {
  User? user;
  try {
    user = FirebaseAuth.instance.currentUser;
  } catch (_) {
    user = null;
  }

  String initialCompany = "";

  if (user != null) {
    try {
      final doc = await FirebaseFirestore.instance
          .collection("users")
          .doc(user.uid)
          .get();

      initialCompany = doc.data()?["company"] as String? ?? "";
    } catch (_) {}
  }

  if (!context.mounted) return null;

  final controller = TextEditingController(text: initialCompany);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text("Company Name"),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(
          labelText: "Company Name",
          hintText: "Shown on the generated report",
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text("Generate"),
        ),
      ],
    ),
  );

  if (confirmed != true) return null;

  final name = controller.text.trim();

  if (user != null && name != initialCompany) {
    try {
      await FirebaseFirestore.instance
          .collection("users")
          .doc(user.uid)
          .update({"company": name});
    } catch (_) {}
  }

  return name;
}
