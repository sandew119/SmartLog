import 'package:flutter/material.dart';

import '../models/log_measurement.dart';
import '../utils/log_volume_pipeline.dart';

enum _Units { imperial, metric }

/// Collects a log's dimensions by hand. Used as the measurement fallback
/// wherever depth scanning isn't available (Android, non-LiDAR iPhones,
/// simulators) and as the escape hatch when a scan comes back too noisy to
/// trust.
Future<LogMeasurement?> showManualMeasurementSheet(
  BuildContext context, {
  String? reason,
}) {
  return showModalBottomSheet<LogMeasurement>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ManualMeasurementSheet(reason: reason),
  );
}

class _ManualMeasurementSheet extends StatefulWidget {
  final String? reason;

  const _ManualMeasurementSheet({this.reason});

  @override
  State<_ManualMeasurementSheet> createState() =>
      _ManualMeasurementSheetState();
}

class _ManualMeasurementSheetState extends State<_ManualMeasurementSheet> {
  final _diameterController = TextEditingController();
  final _lengthController = TextEditingController();

  _Units _units = _Units.imperial;
  String? _error;

  @override
  void dispose() {
    _diameterController.dispose();
    _lengthController.dispose();
    super.dispose();
  }

  String get _diameterUnit => _units == _Units.metric ? "cm" : "inches";
  String get _lengthUnit => _units == _Units.metric ? "m" : "feet";

  void _confirm() {
    final diameterRaw = double.tryParse(_diameterController.text.trim());
    final lengthRaw = double.tryParse(_lengthController.text.trim());

    if (diameterRaw == null || diameterRaw <= 0) {
      setState(() => _error = "Enter a diameter greater than 0.");
      return;
    }

    if (lengthRaw == null || lengthRaw <= 0) {
      setState(() => _error = "Enter a length greater than 0.");
      return;
    }

    // The database stores inches and feet; convert at the boundary so no
    // other layer has to know which units the user typed.
    final diameterInches = _units == _Units.metric
        ? MeasurementUnits.metresToInches(diameterRaw / 100)
        : diameterRaw;

    final lengthFeet = _units == _Units.metric
        ? MeasurementUnits.metresToFeet(lengthRaw)
        : lengthRaw;

    Navigator.pop(
      context,
      LogMeasurement.manual(
        diameterInches: diameterInches,
        lengthFeet: lengthFeet,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // isScrollControlled removes the sheet's default height cap, so an
    // explicit max height is required or tall content renders off-screen
    // instead of scrolling.
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
        child: SingleChildScrollView(
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
                "Enter Log Measurements",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 6),

              Text(
                widget.reason ??
                    "Measure the log at its thinnest point, then enter the "
                        "length.",
                style: const TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 16),

              SegmentedButton<_Units>(
                segments: const [
                  ButtonSegment(
                    value: _Units.imperial,
                    label: Text("Inches / Feet"),
                  ),
                  ButtonSegment(
                    value: _Units.metric,
                    label: Text("cm / m"),
                  ),
                ],
                selected: {_units},
                onSelectionChanged: (selection) {
                  setState(() => _units = selection.first);
                },
              ),

              const SizedBox(height: 16),

              TextField(
                controller: _diameterController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: "Diameter at thinnest point",
                  suffixText: _diameterUnit,
                  border: const OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 12),

              TextField(
                controller: _lengthController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: "Length",
                  suffixText: _lengthUnit,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _confirm(),
              ),

              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],

              const SizedBox(height: 20),

              SizedBox(
                height: 55,
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.check_circle),
                  label: const Text("Use These Measurements"),
                ),
              ),

              const SizedBox(height: 8),

              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
