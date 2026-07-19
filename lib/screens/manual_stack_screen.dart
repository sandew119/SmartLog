import 'package:flutter/material.dart';

class ManualStackScreen extends StatelessWidget {
  const ManualStackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manual Stack"),
      ),
      body: const Center(
        child: Text(
          "Manual Stack Screen",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}