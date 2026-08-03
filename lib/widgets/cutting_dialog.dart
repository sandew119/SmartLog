import 'package:flutter/material.dart';

import '../models/cutting_models.dart';

class CuttingDialog extends StatefulWidget {
  const CuttingDialog({super.key});

  @override
  State<CuttingDialog> createState() =>
      _CuttingDialogState();
}

class _CuttingDialogState
    extends State<CuttingDialog> {
  final _formKey = GlobalKey<FormState>();

  final bladeController =
      TextEditingController(text: "3");

  final boardWidthController =
      TextEditingController(text: "150");

  final boardHeightController =
      TextEditingController(text: "50");

  final diameterController =
      TextEditingController(text: "500");

  final lengthController =
      TextEditingController(text: "3000");

  @override
  void dispose() {
    bladeController.dispose();
    boardWidthController.dispose();
    boardHeightController.dispose();
    diameterController.dispose();
    lengthController.dispose();

    super.dispose();
  }

  Widget numberField({
    required TextEditingController controller,
    required String label,
    required String unit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: TextFormField(
        controller: controller,
        keyboardType:
            const TextInputType.numberWithOptions(
          decimal: true,
        ),
        validator: (value) {
          if (value == null ||
              value.trim().isEmpty) {
            return "Required";
          }

          if (double.tryParse(value) == null) {
            return "Invalid number";
          }

          return null;
        },
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  void generate() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    Navigator.pop(
      context,
      CuttingInput(
        bladeThickness:
            double.parse(bladeController.text),

        boardWidth:
            double.parse(
                boardWidthController.text),

        boardHeight:
            double.parse(
                boardHeightController.text),

        logDiameter:
            double.parse(
                diameterController.text),

        logLength:
            double.parse(
                lengthController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        "Let's Cut This Optimally",
      ),

      content: SizedBox(
        width: 360,

        child: Form(
          key: _formKey,

          child: SingleChildScrollView(
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,

              children: [

                numberField(
                  controller:
                      bladeController,
                  label:
                      "Blade Thickness",
                  unit: "mm",
                ),

                numberField(
                  controller:
                      boardWidthController,
                  label: "Board Width",
                  unit: "mm",
                ),

                numberField(
                  controller:
                      boardHeightController,
                  label: "Board Height",
                  unit: "mm",
                ),

                numberField(
                  controller:
                      diameterController,
                  label: "Log Diameter",
                  unit: "mm",
                ),

                numberField(
                  controller:
                      lengthController,
                  label: "Log Length",
                  unit: "mm",
                ),

              ],
            ),
          ),
        ),
      ),

      actions: [

        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: const Text(
            "Cancel",
          ),
        ),

        ElevatedButton(
          onPressed: generate,
          child: const Text(
            "Generate",
          ),
        ),

      ],
    );
  }
}