import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Rect;

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
/// **Why several passes.** The network sees a 640-pixel square. A phone
/// photo is ~4000 pixels across, so one pass over the whole frame shrinks a
/// thumb-sized knot to a few pixels -- below what the model can resolve, and
/// the reason small defects were being missed. Large photos are therefore
/// scanned five times: once whole (for long cracks that cross the frame) and
/// once per overlapping quarter (for everything small). The passes are
/// merged in `yolo_postprocess.dart`, which also removes the duplicates that
/// used to inflate the count: the same defect seen twice, a box inside a
/// box, and one defect reported under two names.
///
/// **Why a byte buffer.** Frames go to the interpreter as one flat
/// `Float32List` instead of nested Dart lists. The nested form was converted
/// element by element -- 1.2 million conversions per pass -- which is most
/// of what made a scan slow.
///
/// **Why an isolate.** Inference runs through [IsolateInterpreter] so the
/// scanning animation keeps moving. If that path ever fails or stalls, the
/// detector falls back to running on the calling thread for the rest of the
/// session: a frozen second is better than no answer.
///
/// **What could not be confirmed off-device.** The `.tflite` carries no
/// class names or training metadata (an AI Edge / StableHLO export, not
/// Ultralytics' own). Class order comes from the labels file (Crack, Hole,
/// Knot); whether scores need a sigmoid and whether boxes are normalised are
/// both detected from the numbers themselves -- see
/// [decodeYoloDetectionHead]. If a scan reliably calls a crack a knot, the
/// labels file order is the first thing to check.
class YoloDefectDetector implements DefectDetector {
  YoloDefectDetector({
    this.modelAsset = "assets/models/best.tflite",
    this.labelsAsset = "assets/models/best_labels.txt",
    this.scoreThreshold = 0.20,
    this.iouThreshold = 0.45,
    this.tiled = true,
  });

  final String modelAsset;
  final String labelsAsset;

  /// Below this a candidate box is not reported at all.
  ///
  /// Findings between this and [DefectFinding.confidenceThreshold] are shown
  /// and counted but marked "check by eye", and the cutting engine does not
  /// act on them until a person confirms them. The old floor of 0.10 let
  /// through enough noise that the count stopped meaning anything; the tiled
  /// passes lift genuine small defects well clear of this line instead.
  final double scoreThreshold;

  final double iouThreshold;

  /// Whether large photos get the extra per-quarter passes.
  final bool tiled;

  Interpreter? _interpreter;
  IsolateInterpreter? _isolate;
  bool _isolateBroken = false;

  List<String> _labels = const [];

  /// Read from the model's own input tensor, not assumed.
  int _inputSize = 640;
  int _anchors = 0;

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

      // NCHW: [batch, channels, height, width], confirmed from this file's
      // own declared input tensor. An NHWC export would otherwise be fed a
      // scrambled frame that still runs and is simply wrong.
      if (inputShape.length != 4 || inputShape[1] != 3) {
        interpreter.close();
        throw StateError(
          "Expected an NCHW [1, 3, size, size] input, got $inputShape.",
        );
      }

      if (outputShape.length != 3) {
        interpreter.close();
        throw StateError(
          "Expected a single [1, 4+classes, anchors] output, got $outputShape.",
        );
      }

      final expectedClasses = outputShape[1] - 4;

      if (expectedClasses != _labels.length) {
        interpreter.close();

        throw StateError(
          "The model reports $expectedClasses classes but the labels file "
          "lists ${_labels.length}. One of them is wrong, and guessing which "
          "would mislabel every detection.",
        );
      }

      _inputSize = inputShape[2];
      _anchors = outputShape[2];
      _interpreter = interpreter;

      try {
        _isolate = await IsolateInterpreter.create(
          address: interpreter.address,
          debugName: "SmartLogDefects",
        );
      } catch (error) {
        debugPrint("Defect model will run on the main isolate: $error");
        _isolate = null;
      }
    } catch (error) {
      // Not fatal. The screen reports that no model is installed, and
      // marking defects by hand still works.
      debugPrint("YOLO defect model not loaded: $error");
      _interpreter = null;
    }
  }

  @override
  Future<DefectAnalysis> analyse(
    img.Image image, {
    ScanProgress? onProgress,
  }) async {
    final interpreter = _interpreter;
    if (interpreter == null) return const DefectAnalysis();

    final watch = Stopwatch()..start();

    final tiles = tiled
        ? planScanTiles(width: image.width, height: image.height)
        : [
            ScanTile(
              Rect.fromLTWH(
                0,
                0,
                image.width.toDouble(),
                image.height.toDouble(),
              ),
              isWholeImage: true,
            ),
          ];

    onProgress?.call(0, tiles.length);

    // Every tile is cut, resized and packed in one background hop, so the
    // full-resolution photo crosses the isolate boundary once, not per tile.
    final frames = await compute(
      prepareYoloFrames,
      YoloFrameRequest(
        image: image,
        inputSize: _inputSize,
        regions: [
          for (final t in tiles)
            [t.region.left, t.region.top, t.region.width, t.region.height],
        ],
      ),
    );

    final numClasses = _labels.length;
    final channels = 4 + numClasses;

    final placed = <PlacedDetection>[];
    final scores = <String, double>{};

    for (var t = 0; t < tiles.length; t++) {
      final tile = tiles[t];
      final frame = frames[t];

      final flat = await _infer(interpreter, frame.pixels, channels);

      final raw = [
        for (var c = 0; c < channels; c++)
          Float32List.sublistView(flat, c * _anchors, (c + 1) * _anchors),
      ];

      final candidates = decodeYoloDetectionHead(
        raw,
        numClasses: numClasses,
        scoreThreshold: scoreThreshold,
        inputSize: _inputSize,
      );

      final kept = nonMaxSuppression(candidates, iouThreshold: iouThreshold);

      final letterbox = Letterbox(
        inputSize: _inputSize,
        scale: frame.scale,
        padX: frame.padX,
        padY: frame.padY,
        originalWidth: tile.region.width.round(),
        originalHeight: tile.region.height.round(),
      );

      for (final d in kept) {
        final local = letterbox.toOriginal(d.boxInModelSpace);

        placed.add(
          PlacedDetection(
            box: local.shift(tile.region.topLeft),
            classIndex: d.classIndex,
            score: d.score,
          ),
        );
      }

      // The model's own best guess per class from the whole-image pass, kept
      // for diagnostics. Not shown to the user as a number.
      if (tile.isWholeImage) {
        final strongest = strongestPerClass(raw, numClasses: numClasses);

        for (final entry in strongest.entries) {
          if (entry.key >= 0 && entry.key < _labels.length) {
            scores[_labels[entry.key]] = entry.value;
          }
        }
      }

      onProgress?.call(t + 1, tiles.length);
    }

    final merged = dropSpecks(
      mergeDetections(placed),
      imageWidth: image.width,
      imageHeight: image.height,
    );

    watch.stop();

    final findings = <DefectFinding>[];

    for (final d in merged) {
      final label = _labels[d.classIndex];
      final healthy = DefectLabelMap.isHealthy(label);
      final kind = DefectLabelMap.resolve(label);

      // An unmapped label falls back to crack rather than being dropped:
      // silently discarding a finding because the vocabulary disagrees would
      // look exactly like a clean scan.
      final resolved = kind ?? LogDefectKind.crack;

      findings.add(DefectFinding(
        kind: healthy ? LogDefectKind.knot : resolved,
        rawLabel: label,
        confidence: d.score,
        region: d.box,
        isHealthy: healthy,
        support: d.support,
      ));
    }

    return DefectAnalysis(
      findings: findings,
      scores: scores,
      inferenceMs: watch.elapsedMilliseconds,
      passes: tiles.length,
    );
  }

  /// One forward pass, off the main isolate when possible.
  Future<Float32List> _infer(
    Interpreter interpreter,
    Float32List input,
    int channels,
  ) async {
    final output = Float32List(channels * _anchors);

    final isolate = _isolate;

    if (isolate != null && !_isolateBroken) {
      try {
        // The isolate interpreter has no error channel: if inference dies
        // over there, the await below would wait for ever. The timeout is
        // what turns that into a fallback instead of a hung screen.
        await isolate
            .run(input.buffer, output.buffer)
            .timeout(const Duration(seconds: 20));
        return output;
      } catch (error) {
        debugPrint("Isolate inference failed, using main isolate: $error");
        _isolateBroken = true;
      }
    }

    interpreter.run(input.buffer, output.buffer);
    return output;
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
    _isolate?.close();
    _isolate = null;
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

/// What [prepareYoloFrames] needs: the photo, the model's input size, and
/// each region to scan as `[left, top, width, height]` in photo pixels.
class YoloFrameRequest {
  final img.Image image;
  final int inputSize;
  final List<List<double>> regions;

  const YoloFrameRequest({
    required this.image,
    required this.inputSize,
    required this.regions,
  });
}

/// One region, letterboxed and packed for the network.
class YoloFrame {
  /// NCHW float32, 0..1 per channel.
  final Float32List pixels;

  /// The letterbox that was applied, so boxes can be walked back out.
  final double scale;
  final double padX;
  final double padY;

  const YoloFrame({
    required this.pixels,
    required this.scale,
    required this.padX,
    required this.padY,
  });
}

/// Cuts each region out of the photo, fits it inside the model's square
/// without distortion, pads the rest with Ultralytics' mid-grey (114), and
/// packs it as NCHW float32.
///
/// Top level so it runs in a background isolate.
List<YoloFrame> prepareYoloFrames(YoloFrameRequest request) {
  final size = request.inputSize;
  final plane = size * size;
  const pad = 114 / 255.0;

  final frames = <YoloFrame>[];

  for (final region in request.regions) {
    final left = region[0].round().clamp(0, request.image.width - 1);
    final top = region[1].round().clamp(0, request.image.height - 1);
    final width = region[2].round().clamp(1, request.image.width - left);
    final height = region[3].round().clamp(1, request.image.height - top);

    final wholeImage = left == 0 &&
        top == 0 &&
        width == request.image.width &&
        height == request.image.height;

    final source = wholeImage
        ? request.image
        : img.copyCrop(
            request.image,
            x: left,
            y: top,
            width: width,
            height: height,
          );

    final letterbox = Letterbox.fit(
      inputSize: size,
      originalWidth: width,
      originalHeight: height,
    );

    final pixels = Float32List(3 * plane)..fillRange(0, 3 * plane, pad);

    final targetWidth = math.max(1, letterbox.resizedWidth);
    final targetHeight = math.max(1, letterbox.resizedHeight);

    // Averaging, not point-sampling, when shrinking a lot: a hairline crack
    // survives a 6x reduction as a faint dark line instead of vanishing
    // between the sampled pixels.
    final shrink = width / targetWidth;

    final resized = img.copyResize(
      source,
      width: targetWidth,
      height: targetHeight,
      interpolation:
          shrink > 2 ? img.Interpolation.average : img.Interpolation.linear,
    );

    // Flat 8-bit RGB whatever the source was -- a 16-bit or palette PNG from
    // the gallery would otherwise hand back bytes of a different layout.
    final working = (resized.format != img.Format.uint8 ||
            resized.hasPalette ||
            resized.numChannels != 3)
        ? resized.convert(format: img.Format.uint8, numChannels: 3)
        : resized;

    final rgb = working.getBytes(order: img.ChannelOrder.rgb);

    final offsetX = letterbox.padX.round();
    final offsetY = letterbox.padY.round();

    var i = 0;

    for (var y = 0; y < resized.height; y++) {
      final row = (y + offsetY) * size;
      if (y + offsetY >= size) break;

      for (var x = 0; x < resized.width; x++) {
        final column = x + offsetX;

        if (column >= size) {
          i += 3;
          continue;
        }

        final at = row + column;

        pixels[at] = rgb[i] / 255.0;
        pixels[plane + at] = rgb[i + 1] / 255.0;
        pixels[2 * plane + at] = rgb[i + 2] / 255.0;

        i += 3;
      }
    }

    frames.add(
      YoloFrame(
        pixels: pixels,
        scale: letterbox.scale,
        padX: letterbox.padX,
        padY: letterbox.padY,
      ),
    );
  }

  return frames;
}
