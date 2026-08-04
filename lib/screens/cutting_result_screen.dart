import 'dart:io';

import 'package:flutter/material.dart';

import '../models/cutting_models.dart';
import '../painters/cutting_pattern_painter.dart';

class CuttingResultScreen extends StatelessWidget {
  final File imageFile;
  final CuttingResult result;

  const CuttingResultScreen({
    super.key,
    required this.imageFile,
    required this.result,
  });

  Widget statCard(
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
              child: Icon(
                icon,
                color: color,
              ),
            ),

            const SizedBox(width: 15),

            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [

                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.grey,
                    ),
                  ),

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
            )

          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          "Optimal Cutting Result",
        ),
      ),

      body: ListView(

        padding: const EdgeInsets.all(16),

        children: [

          ClipRRect(
            borderRadius:
                BorderRadius.circular(20),
            child: Image.file(
              imageFile,
              height: 220,
              fit: BoxFit.cover,
            ),
          ),

          const SizedBox(height: 20),

          const Text(
            "Generated Cutting Pattern",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 15),

          Container(
            height: 420,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
                  BorderRadius.circular(20),
              border: Border.all(
                color: Colors.grey.shade300,
              ),
            ),
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 5,
              child: CustomPaint(
                size: const Size(
                  700,
                  700,
                ),
                painter:
                    CuttingPatternPainter(
                  result,
                ),
              ),
            ),
          ),

          const SizedBox(height: 25),

          statCard(
            "Boards",
            result.totalBoards.toString(),
            Icons.dashboard,
            Colors.blue,
          ),

          statCard(
            "Yield",
            "${result.utilization.toStringAsFixed(1)} %",
            Icons.pie_chart,
            Colors.green,
          ),

          statCard(
            "Waste",
            "${result.waste.toStringAsFixed(1)} %",
            Icons.delete_outline,
            Colors.red,
          ),

          statCard(
            "Estimated Profit",
            "Rs. ${result.estimatedProfit.toStringAsFixed(2)}",
            Icons.attach_money,
            Colors.orange,
          ),

          const SizedBox(height: 20),

          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
            },
            icon: const Icon(
              Icons.camera_alt,
            ),
            label: const Text(
              "Scan Another Log",
            ),
          ),

          const SizedBox(height: 30),

        ],
      ),
    );
  }
}