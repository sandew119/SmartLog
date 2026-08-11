import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/log_defect.dart';
import 'defect_detector.dart';

/// Runs the fine-tuned ResNet-50 on the device.
///
/// The model classifies the whole image rather than locating anything, so a
/// finding covers the whole frame and the heatmap is what actually says
/// where it looked. When this is replaced by an object detector the
/// [DefectFinding]s gain real boxes and nothing else in the app changes.
class TFLiteDefectDetector implements DefectDetector {
  TFLiteDefectDetector({
    this.modelAsset = "assets/models/wood_defect.tflite",
    this.labelsAsset = "assets/models/wood_defect_labels.txt",
  });

  final String modelAsset;
  final String labelsAsset;

  Interpreter? _interpreter;
  List<String> _labels = const [];

  /// The size the network was trained at.
  static const int inputSize = 224;

  @override
  String get name => _interpreter == null
      ? "ResNet-50 (not loaded)"
      : "ResNet-50 · ${_labels.length} classes";

  @override
  bool get isAvailable => _interpreter != null;

  @override
  Future<void> load() async {
    if (_interpreter != null) return;

    try {
      // Labels first: a model whose classes we cannot name is useless, and
      // failing here costs nothing.
      final raw = await rootBundle.loadString(labelsAsset);

      _labels = [
        for (final line in raw.split("\n"))
          if (line.trim().isNotEmpty) line.trim(),
      ];

      final interpreter = await Interpreter.fromAsset(modelAsset);

      final outputShape = interpreter.getOutputTensor(0).shape;
      final classes = outputShape.last;

      if (classes != _labels.length) {
        interpreter.close();

        throw StateError(
          "The model has $classes outputs but the labels file lists "
          "${_labels.length}. One of them is wrong, and guessing which "
          "would mislabel every prediction.",
        );
      }

      _interpreter = interpreter;
    } catch (error) {
      // Not fatal. The screen reports that no model is installed, and
      // marking defects by hand still works.
      debugPrint("Defect model not loaded: $error");
      _interpreter = null;
    }
  }

  @override
  Future<DefectAnalysis> analyse(img.Image image) async {
    final interpreter = _interpreter;
    if (interpreter == null) return const DefectAnalysis();

    final watch = Stopwatch()..start();

    final input = _prepare(image);

    final output = [List<double>.filled(_labels.length, 0)];
    interpreter.run(input, output);

    watch.stop();

    final probabilities = output.first;

    final scores = <String, double>{
      for (var i = 0; i < _labels.length; i++) _labels[i]: probabilities[i],
    };

    var bestIndex = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[bestIndex]) bestIndex = i;
    }

    final label = _labels[bestIndex];
    final confidence = probabilities[bestIndex];

    final healthy = DefectLabelMap.isHealthy(label);
    final kind = DefectLabelMap.resolve(label);

    // An unmapped, non-healthy label means the labels file and the app's
    // vocabulary disagree. Reporting it as a knot would hide that; treating
    // it as a crack at least routes boards around something the model is
    // confident about, and the raw label is shown so the mismatch is visible.
    final resolved = kind ?? LogDefectKind.crack;

    return DefectAnalysis(
      findings: [
        DefectFinding(
          kind: healthy ? LogDefectKind.knot : resolved,
          rawLabel: label,
          confidence: confidence,
          region: Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          isHealthy: healthy,
        ),
      ],
      scores: scores,
      inferenceMs: watch.elapsedMilliseconds,
    );
  }

  /// Resizes to 224x224 and hands over raw 0-255 RGB.
  ///
  /// Deliberately no normalisation. This model carries its own preprocessing
  /// in its graph -- a channel restack to BGR and a subtraction of the
  /// ImageNet means [103.939, 116.779, 123.680], which is
  /// `resnet50.preprocess_input(mode='caffe')`. Normalising here as well
  /// would apply it twice and quietly destroy the accuracy the notebook
  /// measured.
  List<List<List<List<double>>>> _prepare(img.Image image) {
    final resized = img.copyResize(
      image,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.linear,
    );

    return [
      List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r.toDouble(), p.g.toDouble(), p.b.toDouble()];
        }),
      ),
    ];
  }

  @override
  Future<List<LogDefect>> detect({
    required img.Image image,
    required outline,
  }) async {
    final analysis = await analyse(image);
    return [for (final f in analysis.actionable) f.toDefect()];
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }

  /// Installs this detector if its model asset is present.
  ///
  /// Called once at startup. Silent when the asset is missing, because a
  /// build without the model is a supported build -- everything except
  /// automatic detection works exactly the same.
  static Future<void> installIfAvailable() async {
    final detector = TFLiteDefectDetector();
    await detector.load();

    if (detector.isAvailable) {
      DefectDetection.instance = detector;
    }
  }
}

/// Softmax, for a model whose final layer does not apply one.
///
/// Unused by the current network, which ends in a softmax already. Kept
/// because a retrained model that emits logits is the likeliest next change,
/// and confidences above 1.0 reaching the 0.60 threshold would silently make
/// every prediction actionable.
List<double> softmax(List<double> logits) {
  if (logits.isEmpty) return const [];

  final peak = logits.reduce(math.max);

  final exponentials = [for (final v in logits) math.exp(v - peak)];
  final total = exponentials.reduce((a, b) => a + b);

  if (total <= 0) return List<double>.filled(logits.length, 0);

  return [for (final e in exponentials) e / total];
}
