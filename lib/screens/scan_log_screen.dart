import 'package:flutter/material.dart';

import '../services/lidar_measurement_source.dart';
import '../services/lidar_service.dart';
import '../services/measurement_source.dart';
import 'log_scan_screen.dart';

/// Entry point for measuring a log. Works out how this device can measure,
/// then hands off to [LogScanScreen] with the right measurement source.
///
/// The scan flow is never a dead end: a device without depth scanning gets
/// the same guided screen with manual entry rather than an error.
class ScanLogScreen extends StatefulWidget {
  const ScanLogScreen({super.key});

  @override
  State<ScanLogScreen> createState() => _ScanLogScreenState();
}

class _ScanLogScreenState extends State<ScanLogScreen> {
  bool _checking = true;
  bool _depthAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkCapability();
  }

  Future<void> _checkCapability() async {
    final available =
        await LiDARService.instance.isDepthScanningAvailable();

    if (!mounted) return;

    setState(() {
      _depthAvailable = available;
      _checking = false;
    });

    // Nothing on this screen asks the user anything -- it only works out
    // which measurement source the device supports. Making them read it and
    // press Start put a whole screen between tapping "Scan Log" and seeing
    // a camera, so it now shows only for as long as the check takes.
    _start();
  }

  void _start() {
    final MeasurementSource source = _depthAvailable
        ? const LidarMeasurementSource()
        : const ManualMeasurementSource(
            reason: "This device doesn't have a depth sensor, so enter the "
                "log's dimensions by hand.",
          );

    // Replace rather than push: going back from the scan screen should
    // return home, not to a screen that would immediately forward again.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => LogScanScreen(source: source)),
    );
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
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _depthAvailable ? Icons.sensors : Icons.straighten,
                size: 110,
                color: Colors.green,
              ),

              const SizedBox(height: 25),

              const Text(
                "Measure a Log",
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 15),

              if (_checking)
                const Text(
                  "Checking what this device can measure with...",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                )
              else
                Text(
                  _depthAvailable
                      ? "This device has a depth sensor. Point it at a log to "
                          "measure its diameter and length automatically."
                      : "This device doesn't have a depth sensor, so logs are "
                          "measured by entering dimensions by hand. Everything "
                          "else — stacks, volumes and reports — works the same.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text("Start"),
                  onPressed: _checking ? null : _start,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
