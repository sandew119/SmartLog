import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/log_model.dart';
import '../models/saved_item.dart';
import '../models/stack_model.dart';
import '../repositories/stack_repository.dart';
import '../utils/report_generation.dart';
import 'stack_detail_screen.dart';

class SavedStacksScreen extends StatefulWidget {
  const SavedStacksScreen({super.key});

  @override
  State<SavedStacksScreen> createState() => _SavedStacksScreenState();
}

class _SavedStacksScreenState extends State<SavedStacksScreen> {
  late Future<List<SavedItem>> _future;

  final _dateFormat = DateFormat("MMM d, yyyy • h:mm a");

  @override
  void initState() {
    super.initState();
    _future = StackRepository.instance.loadSavedItems();
  }

  void _reload() {
    setState(() => _future = StackRepository.instance.loadSavedItems());
  }

  Future<void> _openStack(StackModel stack) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StackDetailScreen(stackId: stack.id),
      ),
    );

    _reload();
  }

  Future<void> _showLogDetail(LogModel log) async {
    final action = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Single Log"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Diameter: ${log.diameter.toStringAsFixed(2)} in"),
            Text("Length: ${log.lengthFeet.toStringAsFixed(2)} ft"),
            Text("Volume: ${log.volume.toStringAsFixed(3)} ft³"),
            if (log.cost > 0) Text("Cost: Rs. ${log.cost.toStringAsFixed(2)}"),
            const SizedBox(height: 8),
            Text(
              _dateFormat.format(log.createdAt),
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, "close"),
            child: const Text("Close"),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, "delete"),
            child: const Text("Delete"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, "report"),
            child: const Text("Report"),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (action == "delete") {
      await StackRepository.instance.deleteLog(log.id);
      _reload();
    } else if (action == "report") {
      await generateAndOpenReport(context, standaloneLog: log);
    }
  }

  Widget _buildStackCard(StackModel stack, int logCount) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.green,
          child: Icon(Icons.layers, color: Colors.white),
        ),
        title: Text(
          stack.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          "$logCount logs  •  ${stack.totalVolume.toStringAsFixed(2)} ft³"
          "${stack.totalCost > 0 ? '  •  Rs. ${stack.totalCost.toStringAsFixed(2)}' : ''}"
          "\n${_dateFormat.format(stack.createdAt)}",
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openStack(stack),
      ),
    );
  }

  Widget _buildLogCard(LogModel log) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.brown,
          child: Icon(Icons.forest, color: Colors.white),
        ),
        title: const Text(
          "Single Log",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          "⌀${log.diameter.toStringAsFixed(1)}in × "
          "${log.lengthFeet.toStringAsFixed(1)}ft  •  "
          "${log.volume.toStringAsFixed(2)} ft³"
          "${log.cost > 0 ? '  •  Rs. ${log.cost.toStringAsFixed(2)}' : ''}"
          "\n${_dateFormat.format(log.createdAt)}",
        ),
        isThreeLine: true,
        onTap: () => _showLogDetail(log),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Saved Stacks"),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<SavedItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final items = snapshot.data!;

            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 100),
                  Center(
                    child: Text(
                      "No saved stacks or logs yet.",
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ),
                ],
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];

                return item.stack != null
                    ? _buildStackCard(item.stack!, item.logCount)
                    : _buildLogCard(item.log!);
              },
            );
          },
        ),
      ),
    );
  }
}
