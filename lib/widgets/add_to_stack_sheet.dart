import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../repositories/stack_repository.dart';

/// Shows a sheet letting the user add a measured log (diameter in inches,
/// length in feet -- the same units the local database stores) to an
/// existing stack or a brand new one. Returns the stack id it was added to,
/// or null if the user cancelled.
Future<int?> showAddToStackSheet(
  BuildContext context, {
  required double diameterInches,
  required double lengthFeet,
  required double volumeCubicFeet,
  double cost = 0,
}) async {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddToStackSheet(
      diameterInches: diameterInches,
      lengthFeet: lengthFeet,
      volumeCubicFeet: volumeCubicFeet,
      cost: cost,
    ),
  );
}

class _AddToStackSheet extends StatefulWidget {
  final double diameterInches;
  final double lengthFeet;
  final double volumeCubicFeet;
  final double cost;

  const _AddToStackSheet({
    required this.diameterInches,
    required this.lengthFeet,
    required this.volumeCubicFeet,
    this.cost = 0,
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

        stackId = await StackRepository.instance.createStackAndAddLog(
          name: name,
          diameter: widget.diameterInches,
          lengthFeet: widget.lengthFeet,
          volume: widget.volumeCubicFeet,
          cost: widget.cost,
        );
      } else {
        if (_selectedStackId == null) {
          setState(() => _saving = false);
          return;
        }

        stackId = _selectedStackId!;

        await StackRepository.instance.addLogToStack(
          stackId: stackId,
          diameter: widget.diameterInches,
          lengthFeet: widget.lengthFeet,
          volume: widget.volumeCubicFeet,
          cost: widget.cost,
        );
      }

      if (!mounted) return;
      Navigator.pop(context, stackId);
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
    // showModalBottomSheet(isScrollControlled: true) removes the sheet's
    // default height cap -- without an explicit max height here, content
    // taller than the screen would render past the bottom uncapped rather
    // than scrolling.
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
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
            : SingleChildScrollView(
                child: Column(
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
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
              ),
      ),
    );
  }
}
