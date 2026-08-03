import 'package:flutter/material.dart';

import '../services/lidar_service.dart';
import 'manual_calculator_screen.dart';

class ScanLogScreen extends StatefulWidget {
  const ScanLogScreen({super.key});

  @override
  State<ScanLogScreen> createState() =>
      _ScanLogScreenState();
}

class _ScanLogScreenState
    extends State<ScanLogScreen> {
  bool checking = false;

  Future<void> startScan() async {
    setState(() {
      checking = true;
    });

    final available =
        await LiDARService.instance.isLiDARAvailable();

    if (!mounted) return;

    setState(() {
      checking = false;
    });

    if (available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "LiDAR Detected. Scan module coming next.",
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text(
            "LiDAR Not Available",
          ),
          content: const Text(
            "This device does not support LiDAR scanning.\n\nYou can continue using Manual Measurement.",
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
              onPressed: () {
                Navigator.pop(context);

                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const ManualCalculatorScreen(),
                  ),
                );
              },
              child: const Text(
                "Manual Mode",
              ),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Scan Log"),
        centerTitle: true,
      ),

      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),

          child: Column(
            mainAxisAlignment:
                MainAxisAlignment.center,

            children: [

              const Icon(
                Icons.document_scanner,
                size: 120,
                color: Colors.green,
              ),

              const SizedBox(height: 25),

              const Text(
                "LiDAR Log Scanner",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 15),

              const Text(
                "Measure timber logs automatically using LiDAR.\n\nIf your device doesn't support LiDAR, you can continue using Manual Mode.",
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: checking
                      ? const CircularProgressIndicator(
                          color: Colors.white,
                        )
                      : const Text(
                          "Start Scan",
                        ),
                  onPressed:
                      checking ? null : startScan,
                ),
              ),

              const SizedBox(height: 15),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text(
                    "Go to Manual Mode",
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const ManualCalculatorScreen(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}