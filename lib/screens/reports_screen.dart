import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/saved_item.dart';
import '../repositories/stack_repository.dart';
import '../utils/report_generation.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<List<SavedItem>> _future;
  bool _generating = false;

  final _dateFormat = DateFormat("MMM d, yyyy • h:mm a");

  @override
  void initState() {
    super.initState();
    _future = StackRepository.instance.loadSavedItems();
  }

  Future<void> _generate(SavedItem item) async {
    setState(() => _generating = true);

    if (item.stack != null) {
      await generateAndOpenReport(context, stack: item.stack);
    } else {
      await generateAndOpenReport(context, standaloneLog: item.log);
    }

    if (!mounted) return;
    setState(() => _generating = false);
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

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isStack ? Colors.green : Colors.brown,
          child: Icon(
            isStack ? Icons.layers : Icons.forest,
            color: Colors.white,
          ),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        isThreeLine: true,
        trailing: const Icon(Icons.picture_as_pdf, color: Colors.red),
        onTap: _generating ? null : () => _generate(item),
      ),
    );
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

              if (items.isEmpty) {
                return const Center(
                  child: Text(
                    "Nothing to report on yet.\nSave a stack or log first.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                );
              }

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    "Tap any stack or log to generate a PDF report.",
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 15),
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
