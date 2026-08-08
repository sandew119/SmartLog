import 'package:flutter/material.dart';

import '../database/local_db.dart';
import '../models/log_measurement.dart';
import '../repositories/stack_repository.dart';
import '../services/measurement_source.dart';
import '../services/user_preferences_service.dart';
import '../utils/log_volume_pipeline.dart';
import '../utils/timber_volume.dart';
import '../widgets/choose_stack_sheet.dart';
import '../widgets/manual_measurement_sheet.dart';
import 'stack_detail_screen.dart';

/// Measure a log, see its volume, and add it to a stack.
///
/// Deliberately knows nothing about LiDAR: it drives a [MeasurementSource],
/// so the identical guided flow works on an iPhone with a depth sensor and
/// on an Android phone with a tape measure -- and tests can drive the whole
/// screen by injecting a fake source.
class LogScanScreen extends StatefulWidget {
  /// Injected in tests and by the router; defaults to manual entry, which
  /// is available on every device.
  final MeasurementSource? source;

  final int? initialStackId;

  const LogScanScreen({super.key, this.source, this.initialStackId});

  @override
  State<LogScanScreen> createState() => _LogScanScreenState();
}

class _LogScanScreenState extends State<LogScanScreen> {
  final _prefsService = UserPreferencesService.instance;
  final _priceController = TextEditingController();

  late final MeasurementSource _source =
      widget.source ?? const ManualMeasurementSource();

  int? _activeStackId;
  String? _activeStackName;
  bool _standaloneMode = false;

  double _totalVolume = 0;
  double _totalCost = 0;
  int _logCount = 0;

  LogMeasurement? _measurement;
  VolumeResult? _volume;

  bool _initializing = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prefsService.listenable.addListener(_onPrefsChanged);

    // Deferred to after the first frame: showChooseStackSheet needs a fully
    // mounted context (showModalBottomSheet depends on Localizations),
    // which isn't available while still inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  void _onPrefsChanged() {
    if (!mounted) return;

    // A settings change mid-session must re-price the pending measurement,
    // otherwise the user sees a volume computed with the old method.
    setState(_recomputeVolume);
  }

  @override
  void dispose() {
    _prefsService.listenable.removeListener(_onPrefsChanged);
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (widget.initialStackId != null) {
      await _loadStack(widget.initialStackId!);
      if (mounted) setState(() => _initializing = false);
      return;
    }

    // Deliberately does NOT ask which stack to use yet. That question used
    // to greet the user before they had measured anything -- a decision
    // about filing work that did not exist. It is asked at save time
    // instead, when there is a log in hand and the answer is obvious.
    if (mounted) setState(() => _initializing = false);
  }

  /// Ensures somewhere to file the log, asking only if it is still unknown.
  Future<bool> _ensureDestination() async {
    if (_standaloneMode || _activeStackId != null) return true;

    final choice = await showChooseStackSheet(context);
    if (!mounted) return false;

    if (choice.standalone) {
      setState(() => _standaloneMode = true);
    } else {
      await _loadStack(choice.stackId!);
      if (!mounted) return false;
    }

    return true;
  }

  Future<void> _loadStack(int stackId) async {
    final stackRow = await LocalDB.getStack(stackId);
    if (!mounted || stackRow == null) return;

    final logRows = await LocalDB.getLogsForStack(stackId);
    if (!mounted) return;

    setState(() {
      _activeStackId = stackId;
      _activeStackName = stackRow["name"] as String? ?? "Stack";
      _totalVolume = (stackRow["totalVolume"] as num?)?.toDouble() ?? 0;
      _totalCost = (stackRow["totalCost"] as num?)?.toDouble() ?? 0;
      _logCount = logRows.length;
      _standaloneMode = false;
    });
  }

  void _recomputeVolume() {
    final measurement = _measurement;

    _volume = measurement == null
        ? null
        : volumeForLog(
            prefs: _prefsService.current,
            measuredGirthInches: measurement.minGirthInches,
            lengthFeet: measurement.lengthFeet,
          );
  }

  Future<void> _measure() async {
    setState(() => _busy = true);

    final measurement = await _source.measure(context);

    if (!mounted) return;

    setState(() {
      _busy = false;
      if (measurement != null) {
        _measurement = measurement;
        _recomputeVolume();
      }
    });
  }

  Future<void> _enterManually() async {
    final measurement = await showManualMeasurementSheet(
      context,
      reason: "Enter the log's dimensions by hand.",
    );

    if (!mounted || measurement == null) return;

    setState(() {
      _measurement = measurement;
      _recomputeVolume();
    });
  }

  /// Refuses a measurement the app doesn't trust, and asks for explicit
  /// confirmation on a borderline one. Silently saving a bad number is
  /// worse than refusing to save it -- money changes hands over this.
  Future<bool> _passesQualityGate(LogMeasurement measurement) async {
    switch (measurement.quality) {
      case MeasurementQuality.good:
        return true;

      case MeasurementQuality.fair:
        final proceed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text("Check This Measurement"),
            content: Text(
              measurement.limitingFactorMessage ??
                  "This measurement is less precise than usual.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("Measure Again"),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Save Anyway"),
              ),
            ],
          ),
        );
        return proceed == true;

      case MeasurementQuality.poor:
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text("Measurement Not Reliable"),
            content: Text(
              "${measurement.limitingFactorMessage ?? 'The measurement could not be trusted.'}"
              "\n\nMeasure again, or enter the dimensions by hand.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Close"),
              ),
            ],
          ),
        );
        return false;
    }
  }

  Future<void> _saveLog() async {
    final measurement = _measurement;
    final volume = _volume;
    if (measurement == null || volume == null || _busy) return;

    if (!await _passesQualityGate(measurement)) return;
    if (!mounted) return;

    if (!await _ensureDestination()) return;
    if (!mounted) return;

    setState(() => _busy = true);

    final price = double.tryParse(_priceController.text.trim());
    final cost = (price != null && price > 0)
        ? volume.cubicFeetDecimal * price
        : 0.0;

    final prefs = _prefsService.current;

    // The deduction is a tape allowance, so it is applied in girth and only
    // then converted back: the `logs` table stores diameter because the
    // cutting optimiser and the LiDAR profile both need it.
    //
    // The stored diameter is post-deduction; the raw measurement and the
    // allowance ride along as provenance so the figure can be audited. The
    // allowance is recorded in the same units as the column it explains, so
    // rawDiameterInches - deductionInches == diameter still holds.
    final effectiveGirth = effectiveGirthInches(
      measuredInches: measurement.minGirthInches,
      deductionInches: prefs.girthDeductionInches,
    );

    final storedDiameter =
        TimberVolumeCalculator.diameterInchesFromGirth(effectiveGirth);

    final storedDeduction = TimberVolumeCalculator.diameterInchesFromGirth(
      prefs.girthDeductionInches,
    );

    if (_standaloneMode || _activeStackId == null) {
      await StackRepository.instance.saveStandaloneLog(
        diameter: storedDiameter,
        lengthFeet: measurement.lengthFeet,
        volume: volume.cubicFeetDecimal,
        cost: cost,
        measurement: measurement,
        deductionInches: storedDeduction,
      );
    } else {
      await StackRepository.instance.addLogToStack(
        stackId: _activeStackId!,
        diameter: storedDiameter,
        lengthFeet: measurement.lengthFeet,
        volume: volume.cubicFeetDecimal,
        cost: cost,
        measurement: measurement,
        deductionInches: storedDeduction,
      );
    }

    if (!mounted) return;

    if (_activeStackId != null && !_standaloneMode) {
      await _loadStack(_activeStackId!);
    }

    if (!mounted) return;

    setState(() {
      _busy = false;
      _measurement = null;
      _volume = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _standaloneMode ? "Log saved." : "Added to ${_activeStackName ?? 'stack'}.",
        ),
      ),
    );
  }

  Future<void> _changeStack() async {
    final choice = await showChooseStackSheet(context);
    if (!mounted) return;

    if (choice.standalone) {
      setState(() {
        _standaloneMode = true;
        _activeStackId = null;
        _activeStackName = null;
        _totalVolume = 0;
        _totalCost = 0;
        _logCount = 0;
      });
    } else {
      await _loadStack(choice.stackId!);
    }
  }

  Future<void> _viewStack() async {
    final stackId = _activeStackId;
    if (stackId == null) return;

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StackDetailScreen(stackId: stackId)),
    );

    if (!mounted) return;
    await _loadStack(stackId);
  }

  // --- UI -----------------------------------------------------------------

  Widget _guidanceCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "How to measure — ${_source.label}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ..._source.guidance.asMap().entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${entry.key + 1}.",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.value,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _qualityBadge(MeasurementQuality quality) {
    final (label, color) = switch (quality) {
      MeasurementQuality.good => ("Good", Colors.green),
      MeasurementQuality.fair => ("Check", Colors.orange),
      MeasurementQuality.poor => ("Unreliable", Colors.red),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _resultCard() {
    final measurement = _measurement!;
    final volume = _volume!;
    final prefs = _prefsService.current;

    final deduction = prefs.girthDeductionInches;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  "Measured Log",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _qualityBadge(measurement.quality),
              ],
            ),

            const SizedBox(height: 12),

            _statRow("Girth (thinnest)", measurement.girthDisplay),
            _statRow(
              "Length",
              "${measurement.lengthFeet.toStringAsFixed(2)} ft",
            ),

            if (deduction > 0)
              _statRow(
                "After deduction",
                "${effectiveGirthInches(measuredInches: measurement.minGirthInches, deductionInches: deduction).toStringAsFixed(1)} in "
                    "(−${deduction.toStringAsFixed(1)} in)",
              ),

            const Divider(height: 20),

            Row(
              children: [
                const Text(
                  "Volume",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  prefs.volumeMethod == VolumeMethod.referenceTable
                      ? volume.display
                      : "${volume.cubicFeetDecimal.toStringAsFixed(3)} ft³",
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            if (measurement.limitingFactorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  measurement.limitingFactorMessage!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],

            const SizedBox(height: 16),

            SizedBox(
              height: 50,
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _saveLog,
                icon: const Icon(Icons.add_circle_outline),
                label: Text(
                  _standaloneMode ? "Save Log" : "Add to Stack",
                ),
              ),
            ),

            TextButton(
              onPressed: _busy ? null : _measure,
              child: const Text("Measure Again"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final isStack = !_standaloneMode && _activeStackId != null;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isStack
              ? Colors.green.withValues(alpha: 0.08)
              : Colors.brown.withValues(alpha: 0.08),
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        child: Row(
          children: [
            Icon(
              isStack ? Icons.layers : Icons.forest,
              color: isStack ? Colors.green : Colors.brown,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isStack
                        ? (_activeStackName ?? "Stack")
                        : "Saving logs individually",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isStack)
                    Text(
                      "$_logCount logs  •  ${_totalVolume.toStringAsFixed(2)} ft³"
                      "${_totalCost > 0 ? '  •  Rs. ${_totalCost.toStringAsFixed(2)}' : ''}",
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                ],
              ),
            ),
            if (isStack)
              TextButton(
                onPressed: _busy ? null : _viewStack,
                child: const Text("View"),
              ),
            TextButton(
              onPressed: _busy ? null : _changeStack,
              child: const Text("Change"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Scan Log"),
        centerTitle: true,
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _guidanceCard(),

                if (_measurement != null && _volume != null) _resultCard(),

                if (_measurement == null) ...[
                  SizedBox(
                    height: 55,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _measure,
                      icon: const Icon(Icons.straighten),
                      label: Text(_source.actionLabel),
                    ),
                  ),

                  // Always reachable, so a device whose sensor is struggling
                  // is never a dead end.
                  if (_source is! ManualMeasurementSource) ...[
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _busy ? null : _enterManually,
                      icon: const Icon(Icons.keyboard),
                      label: const Text("Enter measurements by hand"),
                    ),
                  ],
                ],

                const SizedBox(height: 16),

                TextField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: "Price per ft³ (optional)",
                    prefixText: "Rs. ",
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: _initializing ? null : _bottomBar(),
    );
  }
}
