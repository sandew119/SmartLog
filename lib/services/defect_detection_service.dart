class PredictionResult {
  final String label;
  final double confidence;

  PredictionResult({
    required this.label,
    required this.confidence,
  });
}

class DefectDetectionService {
  static final instance = DefectDetectionService();

  Future<void> loadModel() async {}

  Future<PredictionResult> detect(dynamic image) async {
    return PredictionResult(
      label: "Model Not Loaded",
      confidence: 0,
    );
  }

  void dispose() {}
}