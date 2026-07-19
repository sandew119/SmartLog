import 'package:flutter/material.dart';

class OptimalCuttingScreen extends StatelessWidget {
  const OptimalCuttingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Optimal Cutting"),
      ),
      body: const Center(
        child: Text(
          "Optimal Cutting Screen",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}