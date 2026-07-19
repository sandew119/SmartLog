import 'package:flutter/material.dart';

class ScanLogScreen extends StatelessWidget {
  const ScanLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Scan Log"),
      ),
      body: const Center(
        child: Text(
          "Scan Log Screen",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}