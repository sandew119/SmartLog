import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/local_db.dart';
import '../models/log_model.dart';
import '../models/stack_model.dart';
import '../repositories/stack_repository.dart';
import '../utils/report_generation.dart';
import 'manual_calculator_screen.dart';

class StackDetailScreen extends StatefulWidget {
  final int stackId;

  const StackDetailScreen({super.key, required this.stackId});

  @override
  State<StackDetailScreen> createState() => _StackDetailScreenState();
}

class _StackDetailScreenState extends State<StackDetailScreen> {
  final _dateFormat = DateFormat("MMM d, yyyy • h:mm a");

  StackModel? _stack;
  List<LogModel> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stackRow = await LocalDB.getStack(widget.stackId);

    if (!mounted) return;

    if (stackRow == null) {
      Navigator.pop(context);
      return;
    }

    final logRows = await LocalDB.getLogsForStack(widget.stackId);

    if (!mounted) return;

    setState(() {
      _stack = StackModel.fromMap(stackRow);
      _logs = logRows.map(LogModel.fromMap).toList();
      _loading = false;
    });
  }

  Future<void> _addMoreLogs() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ManualCalculatorScreen(initialStackId: widget.stackId),
      ),
    );

    _load();
  }

  Future<void> _generateReport() async {
    if (_stack == null) return;
    await generateAndOpenReport(context, stack: _stack!);
  }

  Future<void> _deleteLog(LogModel log) async {
    await StackRepository.instance.deleteLog(log.id);
    _load();
  }

  Future<void> _deleteStack() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete Stack?"),
        content: Text(
          "This deletes \"${_stack?.name}\" and all ${_logs.length} logs in it. This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await StackRepository.instance.deleteStack(widget.stackId);

    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stack?.name ?? "Stack"),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _loading ? null : _deleteStack,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "${_logs.length} logs  •  "
                        "${_stack!.totalVolume.toStringAsFixed(2)} ft³"
                        "${_stack!.totalCost > 0 ? '  •  Rs. ${_stack!.totalCost.toStringAsFixed(2)}' : ''}",
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Created ${_dateFormat.format(_stack!.createdAt)}",
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _addMoreLogs,
                        icon: const Icon(Icons.add),
                        label: const Text("Add More Logs"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _generateReport,
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text("Report"),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  "Logs in This Stack",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                if (_logs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Text(
                        "No logs in this stack yet.",
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                else
                  ..._logs.map(
                    (log) => Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: const Icon(Icons.forest, color: Colors.brown),
                        title: Text(
                          "⌀${log.diameter.toStringAsFixed(1)}in × "
                          "${log.lengthFeet.toStringAsFixed(1)}ft",
                        ),
                        subtitle: Text(
                          "${log.volume.toStringAsFixed(3)} ft³"
                          "${log.cost > 0 ? '  •  Rs. ${log.cost.toStringAsFixed(2)}' : ''}"
                          "\n${_dateFormat.format(log.createdAt)}",
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => _deleteLog(log),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
