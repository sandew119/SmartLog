import 'package:flutter/material.dart';

class SavedStacksScreen extends StatelessWidget {
  const SavedStacksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Saved Stacks"),
      ),
      body: const Center(
        child: Text(
          "Saved Stacks Screen",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}