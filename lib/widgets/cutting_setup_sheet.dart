import 'package:flutter/material.dart';

import '../models/cutting_models.dart';
import '../utils/calculator.dart';

/// Opens the cutting setup sheet and returns the completed [CuttingInput],
/// or null if the user cancelled.
///
/// If [logDimensions] is provided (e.g. from a LiDAR scan), the log diameter
/// and length fields are shown read-only with a "measured via LiDAR" badge;
/// otherwise they're editable.
Future<CuttingInput?> showCuttingSetupSheet(
  BuildContext context, {
  CuttingInput? logDimensions,
  bool measuredViaLidar = false,
}) {
  return showModalBottomSheet<CuttingInput>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CuttingSetupSheet(
      logDimensions: logDimensions,
      measuredViaLidar: measuredViaLidar,
    ),
  );
}

class CuttingSetupSheet extends StatefulWidget {
  final CuttingInput? logDimensions;
  final bool measuredViaLidar;

  const CuttingSetupSheet({
    super.key,
    this.logDimensions,
    this.measuredViaLidar = false,
  });

  @override
  State<CuttingSetupSheet> createState() => _CuttingSetupSheetState();
}

class _CuttingSetupSheetState extends State<CuttingSetupSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController diameterController;
  late final TextEditingController lengthController;

  final boardWidthController = TextEditingController(text: "150");
  final boardHeightController = TextEditingController(text: "50");
  final bladeController = TextEditingController(text: "3");
  final boardPriceController = TextEditingController(text: "250");

  bool get _logFieldsLocked => widget.logDimensions != null;

  @override
  void initState() {
    super.initState();

    diameterController = TextEditingController(
      text: widget.logDimensions != null
          ? widget.logDimensions!.logDiameter.toStringAsFixed(0)
          : "500",
    );

    lengthController = TextEditingController(
      text: widget.logDimensions != null
          ? widget.logDimensions!.logLength.toStringAsFixed(0)
          : "3000",
    );

    diameterController.addListener(_refresh);
    lengthController.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    diameterController.dispose();
    lengthController.dispose();
    boardWidthController.dispose();
    boardHeightController.dispose();
    bladeController.dispose();
    boardPriceController.dispose();
    super.dispose();
  }

  double? get _volumeCubicFeet {
    final diameterMm = double.tryParse(diameterController.text);
    final lengthMm = double.tryParse(lengthController.text);

    if (diameterMm == null || lengthMm == null) return null;
    if (diameterMm <= 0 || lengthMm <= 0) return null;

    return Calculator.calculateVolume(
      diameter: diameterMm / 25.4,
      lengthFeet: lengthMm / 304.8,
    );
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required String unit,
    bool readOnly = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return "Required";
          }

          final parsed = double.tryParse(value);

          if (parsed == null) {
            return "Invalid number";
          }

          if (parsed <= 0) {
            return "Must be greater than 0";
          }

          return null;
        },
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          filled: readOnly,
          fillColor: Colors.green.withValues(alpha: 0.08),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  void _generate() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.pop(
      context,
      CuttingInput(
        logDiameter: double.parse(diameterController.text),
        logLength: double.parse(lengthController.text),
        boardWidth: double.parse(boardWidthController.text),
        boardHeight: double.parse(boardHeightController.text),
        bladeThickness: double.parse(bladeController.text),
        boardPrice: double.parse(boardPriceController.text),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final volume = _volumeCubicFeet;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Form(
            key: _formKey,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
                  "Let's Cut This Optimally",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _sectionTitle("Log Measurements"),
                    if (widget.measuredViaLidar) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          "Measured via LiDAR",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                _numberField(
                  controller: diameterController,
                  label: "Log Diameter",
                  unit: "mm",
                  readOnly: _logFieldsLocked,
                ),
                _numberField(
                  controller: lengthController,
                  label: "Log Length",
                  unit: "mm",
                  readOnly: _logFieldsLocked,
                ),
                if (volume != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.straighten, color: Colors.blue),
                        const SizedBox(width: 10),
                        Text(
                          "Log Volume: ${volume.toStringAsFixed(2)} ft³",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
                _sectionTitle("Board & Blade Settings"),
                _numberField(
                  controller: boardWidthController,
                  label: "Board Width",
                  unit: "mm",
                ),
                _numberField(
                  controller: boardHeightController,
                  label: "Board Height",
                  unit: "mm",
                ),
                _numberField(
                  controller: bladeController,
                  label: "Blade Thickness (Kerf)",
                  unit: "mm",
                ),
                _numberField(
                  controller: boardPriceController,
                  label: "Price per Board",
                  unit: "Rs.",
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 55,
                  child: ElevatedButton.icon(
                    onPressed: _generate,
                    icon: const Icon(Icons.auto_graph),
                    label: const Text(
                      "Generate Optimal Pattern",
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
