import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/cutting_models.dart';
import '../services/cutting_engine.dart';
import '../widgets/cutting_dialog.dart';
import 'cutting_result_screen.dart';

enum ScanMode {
  manual,
  lidar,
}

class OptimalCuttingScreen extends StatefulWidget {
  const OptimalCuttingScreen({super.key});

  @override
  State<OptimalCuttingScreen> createState() =>
      _OptimalCuttingScreenState();
}

class _OptimalCuttingScreenState
    extends State<OptimalCuttingScreen> {

  CameraController? _cameraController;

  bool cameraLoading = true;
  bool cameraReady = false;

  bool imageCaptured = false;

  XFile? capturedImage;

  ScanMode selectedMode =
      ScanMode.manual;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {

    try {

      final cameras =
          await availableCameras();

      if (cameras.isEmpty) {

        if (!mounted) return;

        setState(() {
          cameraLoading = false;
        });

        return;
      }

      _cameraController =
          CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!
          .initialize();

      if (!mounted) return;

      setState(() {

        cameraLoading = false;
        cameraReady = true;

      });

    } catch (e) {

      if (!mounted) return;

      setState(() {

        cameraLoading = false;
        cameraReady = false;

      });

    }
  }

  Future<void> _captureImage() async {

    if (_cameraController == null) {
      return;
    }

    if (!_cameraController!
        .value
        .isInitialized) {
      return;
    }

    final image =
        await _cameraController!
            .takePicture();

    if (!mounted) return;

    setState(() {

      capturedImage = image;

      imageCaptured = true;

    });
  }

  void _retake() {

    setState(() {

      imageCaptured = false;

      capturedImage = null;

      selectedMode =
          ScanMode.manual;

    });
  }

  Future<void> _generatePattern() async {

    if (capturedImage == null) {
      return;
    }

    final CuttingInput? input =
        await showDialog<CuttingInput>(

      context: context,

      barrierDismissible: false,

      builder: (_) =>
          const CuttingDialog(),
    );

    if (input == null) {
      return;
    }

    final result =
        CuttingEngine.generate(
      input,
    );

    if (!mounted) return;

    Navigator.push(

      context,

      MaterialPageRoute(

        builder: (_) =>
            CuttingResultScreen(

          imageFile:
              File(capturedImage!.path),

          result: result,

        ),
      ),
    );
  }

  @override
  void dispose() {

    _cameraController?.dispose();

    super.dispose();
  }
    Widget _buildCamera() {

    if (cameraLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (!cameraReady) {
      return const Center(
        child: Text(
          "Camera not available",
          style: TextStyle(
            color: Colors.white,
          ),
        ),
      );
    }

    if (imageCaptured) {
      return ClipRRect(
        borderRadius:
            BorderRadius.circular(20),
        child: Image.file(
          File(capturedImage!.path),
          fit: BoxFit.cover,
        ),
      );
    }

    return ClipRRect(
      borderRadius:
          BorderRadius.circular(20),
      child: CameraPreview(
        _cameraController!,
      ),
    );
  }

  Widget _buildCaptureButtons() {

    if (!imageCaptured) {

      return SizedBox(
        width: 260,
        height: 55,
        child: ElevatedButton.icon(
          onPressed: _captureImage,
          icon: const Icon(
            Icons.camera_alt,
          ),
          label: const Text(
            "Capture Log Surface",
          ),
        ),
      );
    }

    return Row(

      children: [

        Expanded(
          child: ElevatedButton.icon(
            onPressed: _retake,
            icon: const Icon(
              Icons.refresh,
            ),
            label: const Text(
              "Retake",
            ),
          ),
        ),

        const SizedBox(width: 15),

        Expanded(
          child: ElevatedButton.icon(
            onPressed: () {
  if (selectedMode == ScanMode.manual) {
    _generatePattern();
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "LiDAR mode is under development.",
        ),
      ),
    );
  }
},
            icon: const Icon(
              Icons.check_circle,
            ),
            label: const Text(
              "Use Photo",
            ),
          ),
        ),

      ],
    );
  }

  Widget _buildModeSelector() {

    if (!imageCaptured) {
      return const SizedBox();
    }

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 20,
      ),
      child: Row(
        children: [

          Expanded(
            child: ElevatedButton(
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    selectedMode ==
                            ScanMode.manual
                        ? Colors.green
                        : Colors.grey.shade300,
                foregroundColor:
                    selectedMode ==
                            ScanMode.manual
                        ? Colors.white
                        : Colors.black,
              ),
              onPressed: () {
                setState(() {
                  selectedMode =
                      ScanMode.manual;
                });
              },
              child: const Text(
                "Manual Mode",
              ),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: ElevatedButton(
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    selectedMode ==
                            ScanMode.lidar
                        ? Colors.green
                        : Colors.grey.shade300,
                foregroundColor:
                    selectedMode ==
                            ScanMode.lidar
                        ? Colors.white
                        : Colors.black,
              ),
              onPressed: () {
                setState(() {
                  selectedMode =
                      ScanMode.lidar;
                });
              },
              child: const Text(
                "LiDAR Mode",
              ),
            ),
          ),

        ],
      ),
    );
  }
    Widget _buildBottomSection() {

    if (!imageCaptured) {
      return const Expanded(
        child: Center(
          child: Text(
            "Capture the log surface to continue.",
            style: TextStyle(
              fontSize: 18,
            ),
          ),
        ),
      );
    }

    if (selectedMode == ScanMode.lidar) {

      return Expanded(
        child: Center(
          child: Column(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: const [

              Icon(
                Icons.sensors,
                size: 90,
                color: Colors.green,
              ),

              SizedBox(height: 20),

              Text(
                "LiDAR Mode",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              SizedBox(height: 15),

              Padding(
                padding:
                    EdgeInsets.symmetric(
                  horizontal: 30,
                ),
                child: Text(
                  "LiDAR optimization is coming soon.\nPlease use Manual Mode.",
                  textAlign:
                      TextAlign.center,
                ),
              ),

            ],
          ),
        ),
      );
    }

    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [

            const Icon(
              Icons.content_cut,
              size: 90,
              color: Colors.green,
            ),

            const SizedBox(height: 20),

            const Text(
              "Manual Optimization",
              style: TextStyle(
                fontSize: 28,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            const SizedBox(height: 15),

            const Padding(
              padding:
                  EdgeInsets.symmetric(
                horizontal: 30,
              ),
              child: Text(
                "Use the captured image together with manual measurements to generate the cutting pattern.",
                textAlign:
                    TextAlign.center,
              ),
            ),

            const SizedBox(height: 30),

            SizedBox(
              width: 280,
              height: 55,
              child: ElevatedButton.icon(
                onPressed:
                    _generatePattern,
                icon: const Icon(
                  Icons.auto_graph,
                ),
                label: const Text(
                  "Let's Cut This Optimally",
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(

      backgroundColor:
          const Color(0xffF5F7FA),

      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          "Optimal Cutting",
        ),
      ),

      body: SafeArea(
        child: Column(
          children: [

            const SizedBox(height: 15),

            const Text(
              "Capture Log Surface",
              style: TextStyle(
                fontSize: 22,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Text(
              imageCaptured
                  ? "Image captured successfully."
                  : "Align the timber log inside the guide.",
              style: const TextStyle(
                color: Colors.grey,
              ),
            ),

            const SizedBox(height: 20),

            Center(
              child: SizedBox(
                width: 320,
                height: 320,
                child: Stack(
                  alignment:
                      Alignment.center,
                  children: [

                    Container(
                      width: 300,
                      height: 300,
                      decoration:
                          BoxDecoration(
                        color:
                            Colors.black,
                        borderRadius:
                            BorderRadius
                                .circular(
                                    20),
                      ),
                      child:
                          _buildCamera(),
                    ),

                    if (!imageCaptured)
                      IgnorePointer(
                        child: Container(
                          width: 240,
                          height: 240,
                          decoration:
                              BoxDecoration(
                            shape:
                                BoxShape
                                    .circle,
                            border:
                                Border.all(
                              color: Colors.green,
                              width: 4,
                            ),
                          ),
                        ),
                      ),

                  ],
                ),
              ),
            ),

            const SizedBox(height: 25),

            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 20,
              ),
              child:
                  _buildCaptureButtons(),
            ),

            const SizedBox(height: 20),

            _buildModeSelector(),

            const SizedBox(height: 10),

            _buildBottomSection(),

          ],
        ),
      ),
    );
  }
}