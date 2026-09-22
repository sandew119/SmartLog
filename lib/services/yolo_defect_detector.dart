import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/log_defect.dart';
import '../utils/yolo_postprocess.dart';
import 'defect_detector.dart';

/// Runs a YOLO object detector on the device: Crack, Hole and Knot, each
/// with its own box, however many appear in one photo.
///
/// Reports one [DefectFinding] per defect found, each boxed to where it
/// actually is -- not one label for the whole photo, which is what a
/// whole-image classifier is stuck with. That is what the overlay needs to
/// draw more than a single heatmap, and what [DefectImpactAnalyser] needs
/// to measure a defect against the traced face rather than assuming it
/// covers the whole log.
///
/// All the arithmetic -- letterboxing, decoding the head, non-max
/// suppression -- lives in `yolo_postprocess.dart`, apart from the
/// interpreter and the `image` package, so it can be checked against scenes
/// built by hand. This class is deliberately thin: prepare a frame, run it,
/// hand the raw tensor to that arithmetic, turn what comes back into
/// [DefectFinding]s.
///
/// **What could not be confirmed off-device.** The `.tflite` this reads
/// carries no class names or training metadata at all -- its only metadata
/// entries are `min_runtime_version` and `keep_stablehlo_constant`, which
/// mark it as converted through Google's AI Edge / StableHLO path rather
/// than Ultralytics' own `model.export()`, which would have embedded them.
/// So two things below are the standard convention for a YOLOv8-and-later
/// detection head, not a fact this file states about itself:
///
/// - **Class order.** The labels file beside this class declares Crack,
///   Hole, Knot, in that order, matching how every training run this project
///   used named its classes. If a scan reliably calls a crack a knot or a
///   hole a crack, this is the first thing to check -- reorder the labels
///   file, not this code.
/// - **Sigmoid.** [decodeYoloDetectionHead] checks the raw scores and
///   applies a sigmoid itself if they look like logits (see its own
///   comment), so a mismatch here degrades to a wrong confidence number
///   rather than a silently broken model.
///
/// A second candidate file existed alongside this one, same architecture
/// signature, no more metadata than this one has. This one was chosen
/// because its filename -- `best.tflite` -- is Ultralytics' own default name
/// for a training run's best checkpoint, which the other file's name was
/// not; that is a naming convention, not a measurement, and was the only
/// signal available to choose between them without a device to test on.
///
/// None of this has been checked against a labelled photo on a real device.
/// Do that first: photograph a log with a crack you can see by eye, confirm
/// the box lands on it and is labelled "Crack" -- and if it is not, the
/// class order is the most likely reason and a three-line fix.
class YoloDefectDetector implements DefectDetector {
  YoloDefectDetector({
    this.modelAsset = "assets/models/best.tflite",
    this.labelsAsset = "assets/models/best_labels.txt",
    this.scoreThreshold = 0.10,
    this.iouThreshold = 0.45,
  });

  final String modelAsset;
  final String labelsAsset;

  /// Below this a candidate box is not reported at all. Deliberately looser
  /// than [DefectFinding.confidenceThreshold] (0.60, which decides what the
  /// cutting engine acts on) -- a finding between the two is still shown to
  /// the user, with the "not sure enough to act on it" message the screen
  /// already has for exactly this case.
  ///
  /// Set low on purpose. A missed defect is a worse failure than an extra
  /// low-confidence one someone has to dismiss by eye, and with no device to
  /// calibrate this against, erring toward showing weak signal rather than
  /// discarding it is the safer direction to be wrong in. Turn it back up
  /// once real photos say this is too permissive, not before.
  final double scoreThreshold;

  final double iouThreshold;

  Interpreter? _interpreter;
  List<String> _labels = const [];

  /// The model's own square input size, read from its input tensor once
  /// loaded rather than assumed, so a re-export at a different resolution
  /// does not silently letterbox to the wrong size.
  int _inputSize = 640;

  @override
  String get name => _interpreter == null
      ? "YOLO defect detector (not loaded)"
      : "YOLO defect detector · ${_labels.length} classes";

  @override
  bool get isAvailable => _interpreter != null;

  @override
  Future<void> load() async {
    if (_interpreter != null) return;

    try {
      final raw = await rootBundle.loadString(labelsAsset);

      _labels = [
        for (final line in raw.split("\n"))
          if (line.trim().isNotEmpty) line.trim(),
      ];

      final interpreter = await Interpreter.fromAsset(modelAsset);

      final inputShape = interpreter.getInputTensor(0).shape;
      final outputShape = interpreter.getOutputTensor(0).shape;

      // NCHW: [batch, channels, height, width]. Confirmed from this file's
      // own declared input tensor, not assumed -- an export that instead
      // produces NHWC would otherwise feed the network a scrambled frame
      // that still runs, still returns numbers, and is simply wrong.
      if (inputShape.length != 4 || inputShape[1] != 3) {
        interpreter.close();
        throw StateError(
          "Expected an NCHW [1, 3, size, size] input, got $inputShape.",
        );
      }

      final declaredSize = inputShape[2];

      if (outputShape.length != 3) {
        interpreter.close();
        throw StateError(
          "Expected a single [1, 4+classes, anchors] output, got $outputShape.",
        );
      }

      final channels = outputShape[1];
      final expectedClasses = channels - 4;

      if (expectedClasses != _labels.length) {
        interpreter.close();

        throw StateError(
          "The model reports $expectedClasses classes but the labels file "
          "lists ${_labels.length}. One of them is wrong, and guessing which "
          "would mislabel every detection.",
        );
      }

      _inputSize = declaredSize;
      _interpreter = interpreter;
    } catch (error) {
      // Not fatal. The screen reports that no model is installed, and
      // marking defects by hand still works.
      debugPrint("YOLO defect model not loaded: $error");
      _interpreter = null;
    }
  }

  @override
  Future<DefectAnalysis> analyse(img.Image image) async {
    final interpreter = _interpreter;
    if (interpreter == null) return const DefectAnalysis();

    final watch = Stopwatch()..start();

    final letterbox = Letterbox.fit(
      inputSize: _inputSize,
      originalWidth: image.width,
      originalHeight: image.height,
    );

    final input = _prepare(image, letterbox);

    final numClasses = _labels.length;
    final numAnchors = interpreter.getOutputTensor(0).shape[2];

    final output = [
      List.generate(4 + numClasses, (_) => List<double>.filled(numAnchors, 0)),
    ];

    interpreter.run(input, output);

    final raw = output[0];

    final candidates = decodeYoloDetectionHead(
      raw,
      numClasses: numClasses,
      scoreThreshold: scoreThreshold,
    );

    final kept = nonMaxSuppression(candidates, iouThreshold: iouThreshold);

    watch.stop();

    final findings = <DefectFinding>[];
    final scores = <String, double>{};

    for (final d in kept) {
      final label = _labels[d.classIndex];
      final healthy = DefectLabelMap.isHealthy(label);
      final kind = DefectLabelMap.resolve(label);

      // See the class comment on DefectLabelMap.resolve for why an unmapped
      // label falls back to crack rather than being dropped: silently
      // discarding a finding because the vocabulary disagrees would look
      // exactly like a clean scan.
      final resolved = kind ?? LogDefectKind.crack;

      findings.add(DefectFinding(
        kind: healthy ? LogDefectKind.knot : resolved,
        rawLabel: label,
        confidence: d.score,
        region: letterbox.toOriginal(d.boxInModelSpace),
        isHealthy: healthy,
      ));
    }

    // The model's own best guess for each class, whether or not anything
    // crossed the threshold. See strongestPerClass's own comment for why:
    // this is what turns "no defects found" into a number someone can act
    // on, rather than a dead end that looks the same whether the model
    // barely looked or looked hard and stayed unconvinced.
    final strongest = strongestPerClass(raw, numClasses: numClasses);

    for (final entry in strongest.entries) {
      if (entry.key >= 0 && entry.key < _labels.length) {
        scores[_labels[entry.key]] = entry.value;
      }
    }

    return DefectAnalysis(
      findings: findings,
      scores: scores,
      inferenceMs: watch.elapsedMilliseconds,
    );
  }

  /// Resizes to fit inside the model's square input and pads the rest with
  /// mid-grey (114, 114, 114) -- Ultralytics' own padding colour, so a photo
  /// goes through the same transform the training images did in Roboflow --
  /// then hands over NCHW float32, 0..1 per channel.
  ///
  /// [box] is returned by the caller for undoing this exact transform on the
  /// way back out; building it here and there from two different formulas
  /// is how a resize and its inverse quietly stop matching.
  List<List<List<List<double>>>> _prepare(img.Image image, Letterbox box) {
    final canvas = img.Image(width: box.inputSize, height: box.inputSize);
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));

    if (box.resizedWidth > 0 && box.resizedHeight > 0) {
      final resized = img.copyResize(
        image,
        width: box.resizedWidth,
        height: box.resizedHeight,
        interpolation: img.Interpolation.linear,
      );

      img.compositeImage(
        canvas,
        resized,
        dstX: box.padX.round(),
        dstY: box.padY.round(),
      );
    }

    final size = box.inputSize;

    final red = List.generate(size, (_) => List<double>.filled(size, 0));
    final green = List.generate(size, (_) => List<double>.filled(size, 0));
    final blue = List.generate(size, (_) => List<double>.filled(size, 0));

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = canvas.getPixel(x, y);
        red[y][x] = p.r / 255.0;
        green[y][x] = p.g / 255.0;
        blue[y][x] = p.b / 255.0;
      }
    }

    return [
      [red, green, blue],
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
    final detector = YoloDefectDetector();
    await detector.load();

    if (detector.isAvailable) {
      DefectDetection.instance = detector;
    }
  }
}
