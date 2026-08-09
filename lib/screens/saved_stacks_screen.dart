import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/log_model.dart';
import '../models/saved_item.dart';
import '../models/stack_model.dart';
import '../repositories/stack_repository.dart';
import '../utils/report_generation.dart';
import '../widgets/cloud_backup_banner.dart';
import 'stack_detail_screen.dart';

class SavedStacksScreen extends StatefulWidget {
  const SavedStacksScreen({super.key});

  @override
  State<SavedStacksScreen> createState() => _SavedStacksScreenState();
}

class _SavedStacksScreenState extends State<SavedStacksScreen> {
  late Future<List<SavedItem>> _future;

  final _dateFormat = DateFormat("MMM d, yyyy • h:mm a");

  final _searchController = TextEditingController();
  DateTimeRange? _dateRange;

  @override
  void initState() {
    super.initState();
    _future = StackRepository.instance.loadSavedItems();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _isFiltering =>
      _searchController.text.trim().isNotEmpty || _dateRange != null;

  void _reload() {
    setState(() {
      _future = _isFiltering
          ? StackRepository.instance.searchSavedItems(
              keyword: _searchController.text,
              from: _dateRange?.start,
              // The picker returns midnight, so an end date chosen as "today"
              // would exclude everything saved today. Extend to the end of
              // that day or the filter silently loses the newest records.
              to: _dateRange == null
                  ? null
                  : DateTime(
                      _dateRange!.end.year,
                      _dateRange!.end.month,
                      _dateRange!.end.day,
                      23,
                      59,
                      59,
                    ),
            )
          : StackRepository.instance.loadSavedItems();
    });
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _dateRange,
    );

    if (picked == null) return;

    setState(() => _dateRange = picked);
    _reload();
  }

  Widget _buildFilters() {
    final range = _dateRange;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (_) => _reload(),
            decoration: InputDecoration(
              hintText: "Search by name, customer or note",
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _reload();
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text(
                    range == null
                        ? "Any date"
                        : "${DateFormat('d MMM').format(range.start)} – "
                            "${DateFormat('d MMM').format(range.end)}",
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (_isFiltering) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _dateRange = null);
                    _reload();
                  },
                  child: const Text("Clear"),
                ),
              ],
            ],
          ),
        ],
      ),
    );
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
      body: Column(
        children: [
          // Above the list, not inside it: this is about all the user's data,
          // not about any one stack, and it must be visible without scrolling.
          const CloudBackupBanner(),
          _buildFilters(),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    return RefreshIndicator(
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
              children: [
                const SizedBox(height: 100),
                Center(
                  child: Text(
                    _isFiltering
                        ? "Nothing matches that search."
                        : "No saved stacks or logs yet.",
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
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
    );
  }
}
