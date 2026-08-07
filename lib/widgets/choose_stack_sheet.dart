import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../repositories/stack_repository.dart';

/// What the user picked in [showChooseStackSheet].
class StackChoice {
  final int? stackId;
  final String? stackName;
  final bool standalone;

  StackChoice.stack(int id, String name)
      : stackId = id,
        stackName = name,
        standalone = false;

  StackChoice.standalone()
      : stackId = null,
        stackName = null,
        standalone = true;
}

/// Shown before any log is measured: create a new stack, pick an existing
/// one, or continue without one (logs get saved individually). Dismissing
/// the sheet (tapping outside it) is treated the same as "continue without
/// a stack" so the user is never stuck unable to proceed.
Future<StackChoice> showChooseStackSheet(BuildContext context) async {
  final result = await showModalBottomSheet<StackChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ChooseStackSheet(),
  );

  return result ?? StackChoice.standalone();
}

class _ChooseStackSheet extends StatefulWidget {
  const _ChooseStackSheet();

  @override
  State<_ChooseStackSheet> createState() => _ChooseStackSheetState();
}

class _ChooseStackSheetState extends State<_ChooseStackSheet> {
  List<Map<String, dynamic>> _stacks = [];
  bool _loading = true;
  bool _creatingNew = false;
  int? _selectedStackId;

  final _newStackNameController = TextEditingController();
  final _customerNameController = TextEditingController();
  final _remarksController = TextEditingController();
  bool _busy = false;

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
    _customerNameController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _confirmStack() async {
    setState(() => _busy = true);

    if (_creatingNew) {
      final name = _newStackNameController.text.trim();

      if (name.isEmpty) {
        setState(() => _busy = false);
        return;
      }

      final stackId = await StackRepository.instance.createEmptyStack(
        name,
        customerName: _customerNameController.text,
        remarks: _remarksController.text,
      );

      if (!mounted) return;
      Navigator.pop(context, StackChoice.stack(stackId, name));
    } else {
      if (_selectedStackId == null) {
        setState(() => _busy = false);
        return;
      }

      final name = _stacks.firstWhere(
            (s) => s["id"] == _selectedStackId,
          )["name"] as String? ??
          "Stack";

      if (!mounted) return;
      Navigator.pop(context, StackChoice.stack(_selectedStackId!, name));
    }
  }

  void _continueStandalone() {
    Navigator.pop(context, StackChoice.standalone());
  }

  @override
  Widget build(BuildContext context) {
    // showModalBottomSheet(isScrollControlled: true) removes the sheet's
    // default height cap, so without an explicit max height here a
    // SingleChildScrollView gets unbounded constraints and never actually
    // clips/scrolls -- it just renders past the bottom of the screen.
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
                      "Start a Stack?",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Group the logs you're about to measure into a stack, or skip this and save each log on its own.",
                      style: TextStyle(color: Colors.grey),
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
                    else ...[
                      TextField(
                        controller: _newStackNameController,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: "New Stack Name",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Both optional. Only the *customer* is asked for --
                      // the user's own company comes from their profile when
                      // a report is generated, never re-typed here.
                      TextField(
                        controller: _customerNameController,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: "Customer Name (optional)",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _remarksController,
                        textInputAction: TextInputAction.done,
                        textCapitalization: TextCapitalization.sentences,
                        maxLines: 2,
                        minLines: 1,
                        decoration: const InputDecoration(
                          labelText: "Remarks (optional)",
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 55,
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : _confirmStack,
                        icon: const Icon(Icons.layers),
                        label: Text(
                            _creatingNew ? "Create Stack" : "Use This Stack"),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _continueStandalone,
                      child: const Text("Continue Without a Stack"),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
