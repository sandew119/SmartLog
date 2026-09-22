import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/local_db.dart';
import '../models/saved_item.dart';
import '../repositories/stack_repository.dart';
import '../theme/app_theme.dart';
import '../utils/report_generation.dart';
import '../widgets/ui_kit.dart';
import 'log_report_builder_screen.dart';
import 'report_preview_screen.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<List<SavedItem>> _future;
  List<Map<String, dynamic>> _passports = const [];
  bool _generating = false;

  final _dateFormat = DateFormat("MMM d, yyyy • h:mm a");

  @override
  void initState() {
    super.initState();
    _future = StackRepository.instance.loadSavedItems();
    _loadPassports();
  }

  /// Log Passports already exported, newest first -- kept so a report
  /// handed to a buyer can be found and re-sent without rebuilding it.
  Future<void> _loadPassports() async {
    try {
      final rows = await LocalDB.getReports(limit: 100);

      final passports = [
        for (final row in rows)
          if ((row["filePath"] as String? ?? "").contains("LogPassport") &&
              File(row["filePath"] as String).existsSync())
            row,
      ];

      // One entry per file: exporting the same passport twice writes the
      // same file, and it should be listed once.
      final seen = <String>{};
      final unique = [
        for (final row in passports)
          if (seen.add(row["filePath"] as String)) row,
      ];

      if (mounted) setState(() => _passports = unique.take(10).toList());
    } catch (_) {}
  }

  Future<void> _generate(SavedItem item) async {
    // PDF to hand over or print, CSV to reconcile in Excel. Asked rather
    // than assumed, because they are genuinely different jobs.
    final format = await showModalBottomSheet<ReportFormat>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.line,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Export as",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              ListTile(
                leading: const IconBadge(
                  icon: Icons.picture_as_pdf_rounded,
                  color: AppTheme.severityHigh,
                ),
                title: const Text("PDF document"),
                subtitle: const Text("For printing or sending to a buyer"),
                onTap: () => Navigator.pop(sheetContext, ReportFormat.pdf),
              ),
              ListTile(
                leading: const IconBadge(
                  icon: Icons.table_chart_rounded,
                  color: AppTheme.success,
                ),
                title: const Text("CSV spreadsheet"),
                subtitle: const Text("Opens in Excel, one row per log"),
                onTap: () => Navigator.pop(sheetContext, ReportFormat.csv),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (format == null || !mounted) return;

    setState(() => _generating = true);

    if (item.stack != null) {
      await generateAndOpenReport(context, stack: item.stack, format: format);
    } else {
      await generateAndOpenReport(
        context,
        standaloneLog: item.log,
        format: format,
      );
    }

    if (!mounted) return;
    setState(() => _generating = false);
  }

  Future<void> _newPassport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LogReportBuilderScreen()),
    );
    _loadPassports();
  }

  Widget _buildCard(SavedItem item) {
    final isStack = item.stack != null;

    final title = isStack ? item.stack!.name : "Single Log";

    final subtitle = isStack
        ? "${item.logCount} logs  •  ${item.stack!.totalVolume.toStringAsFixed(2)} ft³"
            "${item.stack!.totalCost > 0 ? '  •  Rs. ${item.stack!.totalCost.toStringAsFixed(2)}' : ''}"
            "\n${_dateFormat.format(item.stack!.createdAt)}"
        : "⌀${item.log!.diameter.toStringAsFixed(1)}in × "
            "${item.log!.lengthFeet.toStringAsFixed(1)}ft  •  "
            "${item.log!.volume.toStringAsFixed(2)} ft³"
            "${item.log!.cost > 0 ? '  •  Rs. ${item.log!.cost.toStringAsFixed(2)}' : ''}"
            "\n${_dateFormat.format(item.log!.createdAt)}";

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SurfaceCard(
        shadow: false,
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        onTap: _generating ? null : () => _generate(item),
        child: Row(
          children: [
            IconBadge(
              icon: isStack ? Icons.layers_rounded : Icons.forest_rounded,
              color: isStack ? AppTheme.primaryBright : AppTheme.accent,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.ios_share_rounded,
              color: AppTheme.textTertiary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _passportSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PressableScale(
          onTap: _newPassport,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: AppTheme.brandGradient,
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              boxShadow: AppTheme.softShadow,
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: AppTheme.timberGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.assignment_rounded,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "New Log Passport",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        "The full report for a single log",
                        style: TextStyle(
                          color: Color(0xFFCFE0D6),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.add_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
        if (_passports.isNotEmpty) ...[
          const SectionHeader(eyebrow: "Exported", title: "Log Passports"),
          for (final row in _passports)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SurfaceCard(
                shadow: false,
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReportPreviewScreen(
                      pdfFile: File(row["filePath"] as String),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const IconBadge(
                      icon: Icons.assignment_turned_in_rounded,
                      color: AppTheme.accent,
                      size: 38,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _passportName(row["filePath"] as String),
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            "${((row["totalVolumeCubicFeet"] as num?) ?? 0).toStringAsFixed(2)} ft³ · "
                            "${_dateFormat.format(DateTime.tryParse(row["createdAt"] as String? ?? "") ?? DateTime.now())}",
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  static String _passportName(String path) {
    final name = path.split(RegExp(r"[\\/]")).last;
    final ref =
        name.replaceAll("SmartLog_LogPassport_", "").replaceAll(".pdf", "");
    return ref;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Reports"),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          FutureBuilder<List<SavedItem>>(
            future: _future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final items = snapshot.data!;

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                children: [
                  _passportSection(),
                  SectionHeader(
                    eyebrow: "Stacks & logs",
                    title: "Measurement reports",
                    subtitle: items.isEmpty
                        ? null
                        : "Tap any stack or log to generate a PDF report.",
                  ),
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        "Nothing to report on yet.\nSave a stack or log first.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 15,
                        ),
                      ),
                    )
                  else
                    ...items.map(_buildCard),
                ],
              );
            },
          ),
          if (_generating)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
