import 'package:flutter/material.dart';

class DefectDetectionScreen extends StatelessWidget {
  const DefectDetectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Defect Detection"),
      ),
      body: const Center(
        child: Text(
          "Defect Detection Screen",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}