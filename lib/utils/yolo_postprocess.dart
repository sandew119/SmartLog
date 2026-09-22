import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Turns a raw YOLO detection head into boxes, and boxes back into the
/// coordinates of the photograph they came from.
///
/// Kept apart from the TFLite interpreter and the `image` package on
/// purpose, the same way `face_scan.dart` keeps the LiDAR geometry apart
/// from ARKit: this is arithmetic, and arithmetic can be checked against a
/// scene built by hand, on a machine with no phone to run the real model
/// on. `test/yolo_postprocess_test.dart` is where that happens -- every
/// constant here should break one of those tests before it breaks a scan.

/// One box the raw head proposed, before non-max suppression.
class RawDetection {
  /// Centre and size, in the model's own square input space (pixels, not
  /// normalised).
  final double cx, cy, w, h;

  final int classIndex;

  /// 0..1. Already through a sigmoid -- see [decodeYoloDetectionHead].
  final double score;

  const RawDetection({
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.classIndex,
    required this.score,
  });

  Rect get boxInModelSpace =>
      Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h);

  RawDetection copyWith({double? score}) => RawDetection(
        cx: cx,
        cy: cy,
        w: w,
        h: h,
        classIndex: classIndex,
        score: score ?? this.score,
      );
}

double sigmoid(double x) => 1 / (1 + math.exp(-x));

/// Where a letterboxed square sits inside the original photograph.
///
/// The model takes a fixed square frame. A phone photo is almost never
/// square, so it is scaled down to fit inside that square without
/// distorting it, and the leftover strip top-and-bottom or side-to-side is
/// padding -- the same "fit within, pad the rest" the training images went
/// through when Roboflow resized them. A box the model reports has to be
/// walked back through exactly this transform to land on the right place in
/// the original photo, or every finding is offset by however much padding
/// there was.
class Letterbox {
  final int inputSize;

  /// `modelPixels = originalPixels * scale`.
  final double scale;

  final double padX;
  final double padY;

  final int originalWidth;
  final int originalHeight;

  const Letterbox({
    required this.inputSize,
    required this.scale,
    required this.padX,
    required this.padY,
    required this.originalWidth,
    required this.originalHeight,
  });

  factory Letterbox.fit({
    required int inputSize,
    required int originalWidth,
    required int originalHeight,
  }) {
    if (originalWidth <= 0 || originalHeight <= 0) {
      return Letterbox(
        inputSize: inputSize,
        scale: 1,
        padX: 0,
        padY: 0,
        originalWidth: math.max(originalWidth, 1),
        originalHeight: math.max(originalHeight, 1),
      );
    }

    final scale = math.min(
      inputSize / originalWidth,
      inputSize / originalHeight,
    );

    final scaledWidth = originalWidth * scale;
    final scaledHeight = originalHeight * scale;

    return Letterbox(
      inputSize: inputSize,
      scale: scale,
      padX: (inputSize - scaledWidth) / 2,
      padY: (inputSize - scaledHeight) / 2,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
    );
  }

  /// The resized (not yet padded) image dimensions, for compositing onto the
  /// square canvas.
  int get resizedWidth => (originalWidth * scale).round();
  int get resizedHeight => (originalHeight * scale).round();

  /// A box in the model's square, mapped back onto the original photo.
  /// Clamped to the photo's own bounds -- a box the model placed right at
  /// the edge of its padding must not read as running off the real picture.
  Rect toOriginal(Rect modelSpace) {
    double ox(double x) =>
        ((x - padX) / scale).clamp(0.0, originalWidth.toDouble());
    double oy(double y) =>
        ((y - padY) / scale).clamp(0.0, originalHeight.toDouble());

    return Rect.fromLTRB(
      ox(modelSpace.left),
      oy(modelSpace.top),
      ox(modelSpace.right),
      oy(modelSpace.bottom),
    );
  }
}

/// Decodes one raw YOLO detection-head output into candidate boxes, before
/// non-max suppression.
///
/// [raw] is `raw[channel][anchor]` -- exactly the shape
/// `interpreter.run` hands back for this model, `[4 + numClasses][numAnchors]`
/// once the leading batch dimension is stripped. Rows 0-3 are the box, as
/// centre x, centre y, width, height, in the model's own square pixel space
/// (not normalised 0..1 -- confirmed from this file's declared tensor shape,
/// which is the standard raw-head convention for YOLOv8 and later). The
/// rows after that are one per class; anchor-free heads like this one fold
/// objectness into the class score during training, so each row is already
/// that class's own confidence and there is no separate row to multiply in.
///
/// [autoSigmoid] exists because this particular export carries no
/// Ultralytics metadata -- it did not go through `model.export()`'s own
/// path, so whether the graph already applies a sigmoid to those class rows
/// could not be confirmed off-device. A genuine probability never exceeds 1;
/// a value that does is almost certainly a raw logit, so this looks at the
/// largest class score seen across every anchor before any thresholding and,
/// if it is well above 1, applies a sigmoid to all of them. Guessing wrong
/// here is cheap to notice (every detection reads as ~100% or as noise) and
/// expensive to leave silent, so the check runs by default.
///
/// [autoScaleBoxes] exists for the same reason, aimed at rows 0-3 instead:
/// the doc comment above claims those are pixel coordinates in the model's
/// square, the standard convention, but this export's missing metadata
/// cannot confirm it, and some export paths report normalised 0..1 box
/// coordinates instead. Getting this wrong is much quieter than the sigmoid
/// case -- a box that is 1/640th the size it should be still decodes, still
/// letterboxes back onto the photo, and still produces a valid-looking
/// [DefectFinding] with a real label and confidence, it just draws as a rect
/// a fraction of a pixel wide, which is indistinguishable on screen from no
/// box at all. A pixel-space box on a 640-square input routinely reaches
/// into the hundreds; a normalised one never exceeds roughly 1. So this
/// checks the largest magnitude across all four box rows, over every anchor,
/// before thresholding, and multiplies back up by [inputSize] if it looks
/// normalised.
List<RawDetection> decodeYoloDetectionHead(
  List<List<double>> raw, {
  required int numClasses,
  double scoreThreshold = 0.25,
  bool autoSigmoid = true,
  bool autoScaleBoxes = true,
  int inputSize = 640,
}) {
  if (raw.length < 4 + numClasses) return const [];

  final numAnchors = raw[0].length;

  var needsSigmoid = false;

  if (autoSigmoid) {
    var peak = 0.0;
    for (var c = 0; c < numClasses; c++) {
      final row = raw[4 + c];
      for (var a = 0; a < row.length; a++) {
        if (row[a] > peak) peak = row[a];
      }
    }
    needsSigmoid = peak > 1.5;
  }

  var boxScale = 1.0;

  if (autoScaleBoxes) {
    var peak = 0.0;
    for (var c = 0; c < 4; c++) {
      final row = raw[c];
      for (var a = 0; a < row.length; a++) {
        final magnitude = row[a].abs();
        if (magnitude > peak) peak = magnitude;
      }
    }
    if (peak > 0 && peak <= 3.0) boxScale = inputSize.toDouble();
  }

  final out = <RawDetection>[];

  for (var a = 0; a < numAnchors; a++) {
    var bestClass = 0;
    var bestScore = -double.infinity;

    for (var c = 0; c < numClasses; c++) {
      final value = raw[4 + c][a];
      final score = needsSigmoid ? sigmoid(value) : value;
      if (score > bestScore) {
        bestScore = score;
        bestClass = c;
      }
    }

    if (bestScore < scoreThreshold) continue;

    out.add(RawDetection(
      cx: raw[0][a] * boxScale,
      cy: raw[1][a] * boxScale,
      w: raw[2][a] * boxScale,
      h: raw[3][a] * boxScale,
      classIndex: bestClass,
      score: bestScore,
    ));
  }

  return out;
}

/// The single highest score seen for each class, anywhere in the frame,
/// with no threshold applied.
///
/// Not used to decide what counts as a finding -- [decodeYoloDetectionHead]
/// does that. This is for the case that function reports nothing at all: a
/// flat "no defects found" with no number behind it is indistinguishable
/// from a model that never looked, and someone photographing a crack they
/// can see by eye deserves better than that. Knowing the model's own best
/// guess was, say, 8% crack says plainly that it saw something and stayed
/// unconvinced, which points at a different problem (the threshold, the
/// model's training, how the photo was taken) than a true zero would.
Map<int, double> strongestPerClass(
  List<List<double>> raw, {
  required int numClasses,
  bool autoSigmoid = true,
}) {
  if (raw.length < 4 + numClasses) return const {};

  var needsSigmoid = false;

  if (autoSigmoid) {
    var peak = 0.0;
    for (var c = 0; c < numClasses; c++) {
      final row = raw[4 + c];
      for (var a = 0; a < row.length; a++) {
        if (row[a] > peak) peak = row[a];
      }
    }
    needsSigmoid = peak > 1.5;
  }

  final best = <int, double>{};

  for (var c = 0; c < numClasses; c++) {
    final row = raw[4 + c];
    var peak = -double.infinity;

    for (var a = 0; a < row.length; a++) {
      final score = needsSigmoid ? sigmoid(row[a]) : row[a];
      if (score > peak) peak = score;
    }

    best[c] = peak;
  }

  return best;
}

/// Greedy non-max suppression, run separately per class.
///
/// Per class, not across all of them: a crack box and a knot box that
/// happen to overlap describe two different real things, and one must never
/// suppress the other. Within a class, the highest-scoring box in a cluster
/// survives and everything that overlaps it past [iouThreshold] is dropped,
/// repeating until nothing is left to compare.
List<RawDetection> nonMaxSuppression(
  List<RawDetection> detections, {
  double iouThreshold = 0.45,
  int maxPerImage = 50,
}) {
  if (detections.isEmpty) return const [];

  final byClass = <int, List<RawDetection>>{};
  for (final d in detections) {
    byClass.putIfAbsent(d.classIndex, () => []).add(d);
  }

  final kept = <RawDetection>[];

  for (final group in byClass.values) {
    final sorted = [...group]..sort((a, b) => b.score.compareTo(a.score));
    final suppressed = List<bool>.filled(sorted.length, false);

    for (var i = 0; i < sorted.length; i++) {
      if (suppressed[i]) continue;
      kept.add(sorted[i]);

      final a = sorted[i].boxInModelSpace;

      for (var j = i + 1; j < sorted.length; j++) {
        if (suppressed[j]) continue;
        if (_iou(a, sorted[j].boxInModelSpace) > iouThreshold) {
          suppressed[j] = true;
        }
      }
    }
  }

  kept.sort((a, b) => b.score.compareTo(a.score));

  return kept.length > maxPerImage ? kept.sublist(0, maxPerImage) : kept;
}

double _iou(Rect a, Rect b) {
  final intersection = a.intersect(b);
  final interArea =
      intersection.width <= 0 || intersection.height <= 0
          ? 0.0
          : intersection.width * intersection.height;

  final union = a.width * a.height + b.width * b.height - interArea;
  if (union <= 0) return 0;

  return interArea / union;
}
