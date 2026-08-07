import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../models/log_model.dart';
import '../models/stack_model.dart';
import '../repositories/stack_repository.dart';
import '../services/user_preferences_service.dart';
import '../utils/log_volume_pipeline.dart';
import '../utils/timber_volume.dart';
import '../widgets/choose_stack_sheet.dart';

enum _UnitSystem { inchesFeet, centimetersMeters }

class _LogRow {
  final TextEditingController girthController = TextEditingController();
  final TextEditingController lengthController = TextEditingController();
  final FocusNode girthFocus = FocusNode();
  final FocusNode lengthFocus = FocusNode();

  bool saved = false;
  int? logId;
  double cost = 0;

  /// The volume for this row, live. Recomputed on every keystroke while the
  /// row is a draft, then frozen at the value that was actually written to
  /// the database once [saved] is true -- so what the user watched appear is
  /// exactly what got stored.
  VolumeResult? result;

  /// True once both fields hold a usable number, which is what makes the row
  /// worth totalling and worth opening the next one for.
  bool get isComplete => result != null && result!.cubicFeetDecimal > 0;

  void dispose() {
    girthController.dispose();
    lengthController.dispose();
    girthFocus.dispose();
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

  /// Rows with a database write in flight. Guards against the same log being
  /// saved twice when two commit triggers fire together.
  final Set<_LogRow> _committing = {};

  final _prefsService = UserPreferencesService.instance;

  _UnitSystem _unitSystem = _UnitSystem.inchesFeet;

  /// Mirrors the profile setting rather than being independent state: the
  /// toggle below writes through to the user's preferences, so the method
  /// is the same wherever it's changed from.
  VolumeMethod get _method => _prefsService.current.volumeMethod;

  int? _activeStackId;
  String? _activeStackName;
  String? _customerName;
  bool _standaloneMode = false;

  bool _initializing = true;

  String get _girthUnitLabel =>
      _unitSystem == _UnitSystem.centimetersMeters ? "cm" : "in";

  String get _lengthUnitLabel =>
      _unitSystem == _UnitSystem.centimetersMeters ? "m" : "ft";

  @override
  void initState() {
    super.initState();
    _prefsService.listenable.addListener(_onPrefsChanged);

    // The running cost is derived from the price, so typing a price must
    // repaint the total immediately, same as typing a girth does.
    _priceController.addListener(() {
      if (mounted) setState(() {});
    });

    // Defer to after the first frame: showChooseStackSheet needs a fully
    // mounted context (showModalBottomSheet depends on Localizations),
    // which isn't available yet while still inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _prefsService.listenable.removeListener(_onPrefsChanged);

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

    final stack = StackModel.fromMap(stackRow);

    _activeStackId = stackId;
    _activeStackName = stack.name;
    _customerName = stack.customerName;

    // getLogsForStack orders newest-first; show the stack's history oldest
    // to newest, matching the order logs were actually measured in.
    final logs = logRows.map(LogModel.fromMap).toList().reversed;

    for (final log in logs) {
      final row = _LogRow()
        ..saved = true
        ..logId = log.id
        ..cost = log.cost
        ..girthController.text =
            TimberVolumeCalculator.girthInchesFromDiameter(log.diameter)
                .toStringAsFixed(2)
        ..lengthController.text = log.lengthFeet.toStringAsFixed(2);

      row.result = VolumeResult.fromCubicFeet(log.volume);

      _rows.add(row);
    }
  }

  void _addEmptyRow({bool focus = true}) {
    final row = _LogRow();

    // Live recompute on every keystroke: the volume is the whole reason the
    // user is typing, so making them press something to see it is a tax.
    row.girthController.addListener(() => _onRowEdited(row));
    row.lengthController.addListener(() => _onRowEdited(row));

    // Moving on from a finished row saves it. That is the click this form is
    // really trying to remove: the user just keeps typing down the list and
    // every log lands in the stack behind them.
    row.lengthFocus.addListener(() {
      if (!row.lengthFocus.hasFocus && row.isComplete && !row.saved) {
        _commitRow(row);
      }
    });

    setState(() => _rows.add(row));

    if (!focus) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.girthFocus.requestFocus();
    });
  }

  /// Recomputes a draft row's volume and, once it is complete, makes sure
  /// there is an empty row waiting underneath it.
  void _onRowEdited(_LogRow row) {
    if (row.saved) return;

    final girth = _parseGirthInches(row.girthController.text);
    final length = _parseLengthFeet(row.lengthController.text);

    final next = (girth == null || length == null || girth <= 0 || length <= 0)
        ? null
        : volumeForLog(
            prefs: _prefsService.current,
            measuredGirthInches: girth,
            lengthFeet: length,
          );

    if (next?.cubicFeetDecimal == row.result?.cubicFeetDecimal) return;

    setState(() => row.result = next);

    // Open the next row as soon as this one is usable, so a user entering a
    // lorry-load never has to reach for an "add row" button. Only ever grows
    // from the last row, and never steals focus -- the user is still typing.
    if (row.isComplete && identical(row, _rows.last)) {
      _addEmptyRow(focus: false);
    }
  }

  /// The stack total, live: saved logs plus whatever the user is part-way
  /// through typing. Added in the trade's own columns rather than by summing
  /// decimals -- see [StackVolumeTotal].
  StackVolumeTotal get _liveTotal => StackVolumeTotal.of(
        _rows.where((row) => row.isComplete).map((row) => row.result!),
      );

  /// Cost mirrors the volume: only rows that are actually worth something.
  double get _liveCost {
    final price = double.tryParse(_priceController.text.trim());
    if (price == null || price <= 0) return 0;

    return _liveTotal.cubicFeetDecimal * price;
  }

  double? _parseGirthInches(String text) {
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
    if (row.saved || _committing.contains(row)) return;

    final girthInches = _parseGirthInches(row.girthController.text);
    final lengthFeet = _parseLengthFeet(row.lengthController.text);
    final result = row.result;

    if (girthInches == null ||
        lengthFeet == null ||
        girthInches <= 0 ||
        lengthFeet <= 0 ||
        result == null) {
      return;
    }

    // A row can be committed from several places at once (Done on the
    // keyboard also drops focus, which is itself a commit trigger). Without
    // this guard the same log is written to the database twice.
    _committing.add(row);

    // The `logs` table is diameter-canonical (the cutting optimiser and the
    // LiDAR profile both need diameter), so the entered girth is converted
    // on the way in and back again on the way out. The girth deduction is
    // applied first, matching what volumeForLog already billed.
    final storedDiameter = TimberVolumeCalculator.diameterInchesFromGirth(
      effectiveGirthInches(
        measuredInches: girthInches,
        deductionInches: _prefsService.current.girthDeductionInches,
      ),
    );

    final price = double.tryParse(_priceController.text);
    final cost =
        (price != null && price > 0) ? result.cubicFeetDecimal * price : 0.0;

    final int logId;

    if (_standaloneMode) {
      logId = await StackRepository.instance.saveStandaloneLog(
        diameter: storedDiameter,
        lengthFeet: lengthFeet,
        volume: result.cubicFeetDecimal,
        cost: cost,
      );
    } else {
      logId = await StackRepository.instance.addLogToStack(
        stackId: _activeStackId!,
        diameter: storedDiameter,
        lengthFeet: lengthFeet,
        volume: result.cubicFeetDecimal,
        cost: cost,
      );
    }

    _committing.remove(row);
    if (!mounted) return;

    setState(() {
      row.saved = true;
      row.logId = logId;
      row.cost = cost;
    });

    // A completed row already opened the next one as it was typed; this only
    // covers the edge case of the very last row being committed directly.
    if (_rows.every((r) => r.saved)) _addEmptyRow(focus: false);
  }

  Future<void> _deleteRow(_LogRow row) async {
    if (row.logId == null) return;

    await StackRepository.instance.deleteLog(row.logId!);

    if (!mounted) return;

    setState(() {
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
    _activeStackId = null;
    _activeStackName = null;
    _customerName = null;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _standaloneMode
                      ? "Saving logs individually"
                      : (_activeStackName ?? "Stack"),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                // The running total lives in the bar at the bottom, so this
                // space goes to who the stack is for instead.
                if (_customerName != null)
                  Text(
                    _customerName!,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
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
            title: const Text("Sri Lankan Method"),
            subtitle: Text(
              _method == VolumeMethod.referenceTable
                  ? "Volumes shown as adi + angal, from the timber ready-reckoner."
                  : "Volumes shown as decimal cubic feet (standard formula).",
              style: const TextStyle(fontSize: 12),
            ),
            value: _method == VolumeMethod.referenceTable,
            onChanged: (value) {
              // Writes through to the profile setting so there is one source
              // of truth; the listener installed in initState rebuilds this.
              _prefsService.setVolumeMethod(
                value ? VolumeMethod.referenceTable : VolumeMethod.standard,
              );
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  /// One log's volume, in whichever units the user's chosen method speaks.
  String _volumeLabel(VolumeResult? result) {
    if (result == null) return "—";

    return _method == VolumeMethod.referenceTable
        ? result.bookDisplay
        : "${result.cubicFeetDecimal.toStringAsFixed(3)} ft³";
  }

  /// The always-visible running total. Pinned to the bottom of the screen
  /// rather than buried at the end of the list: on a lorry-load of logs the
  /// list is far longer than the screen, and this is the number the user is
  /// actually there for.
  Widget _buildTotalBar() {
    final total = _liveTotal;
    final cost = _liveCost;
    final pending = _rows.where((r) => r.isComplete && !r.saved).length;

    return Material(
      elevation: 8,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        color: Colors.green.shade50,
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _standaloneMode ? "Total entered" : "Stack total",
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      _method == VolumeMethod.referenceTable
                          ? total.display
                          : "${total.cubicFeetDecimal.toStringAsFixed(3)} ft³",
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    total.logCount == 1 ? "1 log" : "${total.logCount} logs",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (cost > 0)
                    Text(
                      "Rs. ${cost.toStringAsFixed(2)}",
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (pending > 0)
                    Text(
                      "$pending not saved yet",
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.blue.shade700,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
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
            child: Text("Girth ($_girthUnitLabel)", style: style),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: Text("Length ($_lengthUnitLabel)", style: style),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: Text(
              _method == VolumeMethod.referenceTable
                  ? "Volume (adi · angal)"
                  : "Volume (ft³)",
              style: style,
            ),
          ),
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
                    controller: row.girthController,
                    focusNode: row.girthFocus,
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
                : Text(row.girthController.text),
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
              _volumeLabel(row.result),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                // A draft reads slightly lighter than a saved row, so the
                // user can see at a glance what has actually landed.
                color: row.saved ? Colors.black87 : Colors.blue.shade700,
              ),
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
                    // Keeps the row being typed clear of the keyboard.
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: _rows.length,
                    itemBuilder: (context, index) =>
                        _buildRow(index, _rows[index]),
                  ),
                ),
                _buildTotalBar(),
              ],
            ),
    );
  }
}
