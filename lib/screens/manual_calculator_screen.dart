import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../models/log_model.dart';
import '../repositories/stack_repository.dart';
import '../utils/timber_volume.dart';
import '../widgets/choose_stack_sheet.dart';

enum _UnitSystem { inchesFeet, centimetersMeters }

class _LogRow {
  final TextEditingController diameterController = TextEditingController();
  final TextEditingController lengthController = TextEditingController();
  final FocusNode diameterFocus = FocusNode();
  final FocusNode lengthFocus = FocusNode();

  bool saved = false;
  int? logId;
  double cost = 0;
  VolumeResult? result;

  void dispose() {
    diameterController.dispose();
    lengthController.dispose();
    diameterFocus.dispose();
    lengthFocus.dispose();
  }
}

class ManualCalculatorScreen extends StatefulWidget {
  final int? initialStackId;

  const ManualCalculatorScreen({super.key, this.initialStackId});

  @override
  State<ManualCalculatorScreen> createState() => _ManualCalculatorScreenState();
}

class _ManualCalculatorScreenState extends State<ManualCalculatorScreen> {
  final List<_LogRow> _rows = [];
  final _priceController = TextEditingController();

  _UnitSystem _unitSystem = _UnitSystem.inchesFeet;
  VolumeMethod _method = VolumeMethod.standard;

  int? _activeStackId;
  String? _activeStackName;
  bool _standaloneMode = false;

  double _totalVolume = 0;
  double _totalCost = 0;

  bool _initializing = true;

  String get _diameterUnitLabel =>
      _unitSystem == _UnitSystem.centimetersMeters ? "cm" : "in";

  String get _lengthUnitLabel =>
      _unitSystem == _UnitSystem.centimetersMeters ? "m" : "ft";

  @override
  void initState() {
    super.initState();
    // Defer to after the first frame: showChooseStackSheet needs a fully
    // mounted context (showModalBottomSheet depends on Localizations),
    // which isn't available yet while still inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    bool stackChoiceMade = false;

    if (widget.initialStackId != null) {
      await _loadExistingStack(widget.initialStackId!);
      stackChoiceMade = true;
    }

    if (!mounted) return;
    setState(() => _initializing = false);

    if (!stackChoiceMade) {
      final choice = await showChooseStackSheet(context);
      if (!mounted) return;

      setState(() {
        if (choice.standalone) {
          _standaloneMode = true;
        } else {
          _activeStackId = choice.stackId;
          _activeStackName = choice.stackName;
        }
      });
    }

    _addEmptyRow();
  }

  Future<void> _loadExistingStack(int stackId) async {
    final stackRow = await LocalDB.getStack(stackId);
    if (stackRow == null) return;

    final logRows = await LocalDB.getLogsForStack(stackId);

    _activeStackId = stackId;
    _activeStackName = stackRow["name"] as String? ?? "Stack";
    _totalVolume = (stackRow["totalVolume"] as num?)?.toDouble() ?? 0;
    _totalCost = (stackRow["totalCost"] as num?)?.toDouble() ?? 0;

    // getLogsForStack orders newest-first; show the stack's history oldest
    // to newest, matching the order logs were actually measured in.
    final logs = logRows.map(LogModel.fromMap).toList().reversed;

    for (final log in logs) {
      final row = _LogRow()
        ..saved = true
        ..logId = log.id
        ..cost = log.cost
        ..diameterController.text = log.diameter.toStringAsFixed(2)
        ..lengthController.text = log.lengthFeet.toStringAsFixed(2);

      final wholeFeet = log.volume.floor();

      row.result = VolumeResult(
        cubicFeetDecimal: log.volume,
        wholeCubicFeet: wholeFeet,
        remainderCubicInches: ((log.volume - wholeFeet) * 1728).round(),
      );

      _rows.add(row);
    }
  }

  void _addEmptyRow() {
    final row = _LogRow();

    setState(() => _rows.add(row));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.diameterFocus.requestFocus();
    });
  }

  double? _parseDiameterInches(String text) {
    final value = double.tryParse(text);
    if (value == null) return null;

    return _unitSystem == _UnitSystem.centimetersMeters ? value / 2.54 : value;
  }

  double? _parseLengthFeet(String text) {
    final value = double.tryParse(text);
    if (value == null) return null;

    return _unitSystem == _UnitSystem.centimetersMeters
        ? value * 3.28084
        : value;
  }

  Future<void> _commitRow(_LogRow row) async {
    if (row.saved) return;

    final diameterInches = _parseDiameterInches(row.diameterController.text);
    final lengthFeet = _parseLengthFeet(row.lengthController.text);

    if (diameterInches == null ||
        lengthFeet == null ||
        diameterInches <= 0 ||
        lengthFeet <= 0) {
      return;
    }

    final result = TimberVolumeCalculator.calculate(
      method: _method,
      diameterInches: diameterInches,
      lengthFeet: lengthFeet,
    );

    final price = double.tryParse(_priceController.text);
    final cost =
        (price != null && price > 0) ? result.cubicFeetDecimal * price : 0.0;

    final int logId;

    if (_standaloneMode) {
      logId = await StackRepository.instance.saveStandaloneLog(
        diameter: diameterInches,
        lengthFeet: lengthFeet,
        volume: result.cubicFeetDecimal,
        cost: cost,
      );
    } else {
      logId = await StackRepository.instance.addLogToStack(
        stackId: _activeStackId!,
        diameter: diameterInches,
        lengthFeet: lengthFeet,
        volume: result.cubicFeetDecimal,
        cost: cost,
      );
    }

    if (!mounted) return;

    setState(() {
      row.saved = true;
      row.logId = logId;
      row.cost = cost;
      row.result = result;

      if (!_standaloneMode) {
        _totalVolume += result.cubicFeetDecimal;
        _totalCost += cost;
      }
    });

    _addEmptyRow();
  }

  Future<void> _deleteRow(_LogRow row) async {
    if (row.logId == null) return;

    await StackRepository.instance.deleteLog(row.logId!);

    if (!mounted) return;

    setState(() {
      if (!_standaloneMode) {
        _totalVolume -= row.result?.cubicFeetDecimal ?? 0;
        _totalCost -= row.cost;
      }
      _rows.remove(row);
      row.dispose();
    });
  }

  Future<void> _changeStack() async {
    final choice = await showChooseStackSheet(context);
    if (!mounted) return;

    for (final row in List<_LogRow>.from(_rows)) {
      row.dispose();
    }
    _rows.clear();
    _totalVolume = 0;
    _totalCost = 0;
    _activeStackId = null;
    _activeStackName = null;
    _standaloneMode = false;

    if (choice.standalone) {
      setState(() => _standaloneMode = true);
    } else {
      await _loadExistingStack(choice.stackId!);
      setState(() {});
    }

    _addEmptyRow();
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: _standaloneMode
          ? Colors.brown.withValues(alpha: 0.08)
          : Colors.green.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(
            _standaloneMode ? Icons.forest : Icons.layers,
            color: _standaloneMode ? Colors.brown : Colors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _standaloneMode
                  ? "Saving logs individually"
                  : (_activeStackName ?? "Stack"),
              style: const TextStyle(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!_standaloneMode)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                "${_totalVolume.toStringAsFixed(2)} ft³"
                "${_totalCost > 0 ? ' • Rs. ${_totalCost.toStringAsFixed(2)}' : ''}",
                style: const TextStyle(fontSize: 12),
              ),
            ),
          TextButton(
            onPressed: _changeStack,
            child: const Text("Change"),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<_UnitSystem>(
                  initialValue: _unitSystem,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: "Units",
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: _UnitSystem.inchesFeet,
                      child: Text("Inches / Feet"),
                    ),
                    DropdownMenuItem(
                      value: _UnitSystem.centimetersMeters,
                      child: Text("Centimeters / Meters"),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _unitSystem = value);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: "Price/ft³ (optional)",
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Reference Table Volume"),
            subtitle: Text(
              _method == VolumeMethod.referenceTable
                  ? "New logs show volume as whole cubic feet + inches (traditional timber table method)."
                  : "New logs show volume as a decimal cubic-feet number (standard formula).",
              style: const TextStyle(fontSize: 12),
            ),
            value: _method == VolumeMethod.referenceTable,
            onChanged: (value) {
              setState(() {
                _method =
                    value ? VolumeMethod.referenceTable : VolumeMethod.standard;
              });
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _columnHeader() {
    const style = TextStyle(fontWeight: FontWeight.bold, fontSize: 12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.grey.shade100,
      child: Row(
        children: [
          const SizedBox(width: 28, child: Text("#", style: style)),
          Expanded(
            flex: 2,
            child: Text("Diameter ($_diameterUnitLabel)", style: style),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: Text("Length ($_lengthUnitLabel)", style: style),
          ),
          const SizedBox(width: 6),
          const Expanded(flex: 3, child: Text("Volume", style: style)),
          const SizedBox(width: 36),
        ],
      ),
    );
  }

  Widget _buildRow(int index, _LogRow row) {
    final bool editable = !row.saved;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: index.isEven ? Colors.white : Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 28, child: Text("${index + 1}")),
          Expanded(
            flex: 2,
            child: editable
                ? TextField(
                    controller: row.diameterController,
                    focusNode: row.diameterFocus,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => row.lengthFocus.requestFocus(),
                  )
                : Text(row.diameterController.text),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: editable
                ? TextField(
                    controller: row.lengthController,
                    focusNode: row.lengthFocus,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _commitRow(row),
                  )
                : Text(row.lengthController.text),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: Text(
              row.result == null
                  ? "-"
                  : (_method == VolumeMethod.referenceTable
                      ? row.result!.display
                      : "${row.result!.cubicFeetDecimal.toStringAsFixed(3)} ft³"),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            width: 36,
            child: editable
                ? IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 22,
                    ),
                    onPressed: () => _commitRow(row),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                    onPressed: () => _deleteRow(row),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manual Calculator"),
        centerTitle: true,
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildHeader(),
                _buildToolbar(),
                _columnHeader(),
                Expanded(
                  child: ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (context, index) =>
                        _buildRow(index, _rows[index]),
                  ),
                ),
              ],
            ),
    );
  }
}
