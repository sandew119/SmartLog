import 'dart:io';

import 'package:flutter/material.dart';

import '../models/cutting_models.dart';
import '../painters/cutting_pattern_painter.dart';
import '../utils/calculator.dart';
import '../widgets/add_to_stack_sheet.dart';

class CuttingResultScreen extends StatefulWidget {
  final File? imageFile;
  final CuttingInput input;
  final CuttingResult result;

  const CuttingResultScreen({
    super.key,
    this.imageFile,
    required this.input,
    required this.result,
  });

  @override
  State<CuttingResultScreen> createState() => _CuttingResultScreenState();
}

class _CuttingResultScreenState extends State<CuttingResultScreen> {
  double get _volumeCubicFeet => Calculator.calculateVolume(
        diameter: widget.input.logDiameter / 25.4,
        lengthFeet: widget.input.logLength / 304.8,
      );

  Widget _statCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Card(
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 15),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 5),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoOrPlaceholder() {
    if (widget.imageFile != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.file(
          widget.imageFile!,
          height: 220,
          width: double.infinity,
          fit: BoxFit.cover,
        ),
      );
    }

    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.forest, size: 48, color: Colors.grey),
            SizedBox(height: 8),
            Text(
              "No photo — manual measurements only",
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addToStack() async {
    final stackId = await showAddToStackSheet(
      context,
      diameterInches: widget.input.logDiameter / 25.4,
      lengthFeet: widget.input.logLength / 304.8,
      volumeCubicFeet: _volumeCubicFeet,
    );

    if (!mounted) return;

    if (stackId != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Added to stack.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text("Optimal Cutting Result"),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPhotoOrPlaceholder(),
          const SizedBox(height: 20),
          const Text(
            "Generated Cutting Pattern",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 15),
          Container(
            height: 420,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 5,
              child: CustomPaint(
                size: const Size(700, 700),
                painter: CuttingPatternPainter(result),
              ),
            ),
          ),
          const SizedBox(height: 25),
          _statCard(
            "Boards",
            result.boardCount.toString(),
            Icons.dashboard,
            Colors.blue,
          ),
          _statCard(
            "Yield",
            "${result.utilization.toStringAsFixed(1)} %",
            Icons.pie_chart,
            Colors.green,
          ),
          _statCard(
            "Waste",
            "${result.waste.toStringAsFixed(1)} %",
            Icons.delete_outline,
            Colors.red,
          ),
          _statCard(
            "Kerf Loss",
            "${result.kerfLoss.toStringAsFixed(0)} mm²",
            Icons.content_cut,
            Colors.brown,
          ),
          _statCard(
            "Estimated Profit",
            "Rs. ${result.profit.toStringAsFixed(2)}",
            Icons.attach_money,
            Colors.orange,
          ),
          _statCard(
            "Log Volume",
            "${_volumeCubicFeet.toStringAsFixed(2)} ft³",
            Icons.straighten,
            Colors.teal,
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 55,
            child: ElevatedButton.icon(
              onPressed: _addToStack,
              icon: const Icon(Icons.layers),
              label: const Text("Add to Stack"),
            ),
          ),
          const SizedBox(height: 15),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.popUntil(context, (route) => route.isFirst);
            },
            icon: const Icon(Icons.home),
            label: const Text("Back to Home"),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
