import 'package:flutter/material.dart';

import '../database/local_db.dart';

/// Shows a sheet letting the user add a measured log (diameter/length in mm,
/// volume already in cubic feet) to an existing stack or a brand new one.
/// Returns true if the log was added.
Future<bool> showAddToStackSheet(
  BuildContext context, {
  required double diameterMm,
  required double lengthMm,
  required double volumeCubicFeet,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddToStackSheet(
      diameterMm: diameterMm,
      lengthMm: lengthMm,
      volumeCubicFeet: volumeCubicFeet,
    ),
  );

  return result ?? false;
}

class _AddToStackSheet extends StatefulWidget {
  final double diameterMm;
  final double lengthMm;
  final double volumeCubicFeet;

  const _AddToStackSheet({
    required this.diameterMm,
    required this.lengthMm,
    required this.volumeCubicFeet,
  });

  @override
  State<_AddToStackSheet> createState() => _AddToStackSheetState();
}

class _AddToStackSheetState extends State<_AddToStackSheet> {
  List<Map<String, dynamic>> _stacks = [];
  bool _loading = true;
  bool _creatingNew = false;
  int? _selectedStackId;

  final _newStackNameController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadStacks();
  }

  Future<void> _loadStacks() async {
    final stacks = await LocalDB.getStacks();

    if (!mounted) return;

    setState(() {
      _stacks = stacks;
      _creatingNew = stacks.isEmpty;
      _selectedStackId = stacks.isNotEmpty ? stacks.first["id"] as int : null;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _newStackNameController.dispose();
    super.dispose();
  }

  double get _diameterInches => widget.diameterMm / 25.4;
  double get _lengthFeet => widget.lengthMm / 304.8;

  Future<void> _confirm() async {
    setState(() => _saving = true);

    try {
      int stackId;

      if (_creatingNew) {
        final name = _newStackNameController.text.trim();

        if (name.isEmpty) {
          setState(() => _saving = false);
          return;
        }

        stackId = await LocalDB.createStack(name, 0);
      } else {
        if (_selectedStackId == null) {
          setState(() => _saving = false);
          return;
        }

        stackId = _selectedStackId!;
      }

      await LocalDB.addLogAndUpdateStackVolume(
        stackId: stackId,
        diameter: _diameterInches,
        lengthFeet: _lengthFeet,
        volume: widget.volumeCubicFeet,
      );

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Could not save to stack.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: _loading
          ? const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const Text(
                  "Add This Log to a Stack",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  "Volume: ${widget.volumeCubicFeet.toStringAsFixed(2)} ft³",
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 20),
                if (_stacks.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Text("Existing Stack"),
                          selected: !_creatingNew,
                          onSelected: (_) =>
                              setState(() => _creatingNew = false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ChoiceChip(
                          label: const Text("New Stack"),
                          selected: _creatingNew,
                          onSelected: (_) =>
                              setState(() => _creatingNew = true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                if (!_creatingNew)
                  DropdownButtonFormField<int>(
                    initialValue: _selectedStackId,
                    decoration: const InputDecoration(
                      labelText: "Select Stack",
                      border: OutlineInputBorder(),
                    ),
                    items: _stacks
                        .map(
                          (s) => DropdownMenuItem<int>(
                            value: s["id"] as int,
                            child: Text(s["name"] as String? ?? "Stack"),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedStackId = value),
                  )
                else
                  TextField(
                    controller: _newStackNameController,
                    decoration: const InputDecoration(
                      labelText: "New Stack Name",
                      border: OutlineInputBorder(),
                    ),
                  ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 55,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _confirm,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.layers),
                    label: const Text("Add to Stack"),
                  ),
                ),
              ],
            ),
    );
  }
}
