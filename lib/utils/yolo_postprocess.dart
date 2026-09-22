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

  Rect get boxInModelSpace => Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h);

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
  final interArea = intersection.width <= 0 || intersection.height <= 0
      ? 0.0
      : intersection.width * intersection.height;

  final union = a.width * a.height + b.width * b.height - interArea;
  if (union <= 0) return 0;

  return interArea / union;
}

/// Intersection over the *smaller* box's area.
///
/// IoU cannot see a small box sitting wholly inside a big one: a knot boxed
/// once tightly and once loosely scores an IoU of perhaps 0.2, well under any
/// sensible suppression threshold, and is then counted twice. Measured
/// against the smaller box, full containment reads as 1.0, which is what it
/// is -- the same defect.
double intersectionOverSmaller(Rect a, Rect b) {
  final intersection = a.intersect(b);
  if (intersection.width <= 0 || intersection.height <= 0) return 0;

  final smaller = math.min(a.width * a.height, b.width * b.height);
  if (smaller <= 0) return 0;

  return (intersection.width * intersection.height) / smaller;
}

double intersectionOverUnion(Rect a, Rect b) => _iou(a, b);

/// One region of the photograph the model is run on.
///
/// The model sees a 640-pixel square. A phone photograph is 4000 pixels
/// across, so squeezing all of it into one pass shrinks a thumbnail-sized
/// knot to three or four pixels -- below what the network can resolve, and
/// the reason small defects were going unreported. Running it again on
/// overlapping quarters of the photo gives each of those defects six times
/// the pixels, while the whole-image pass still catches the long cracks that
/// cross tile borders.
class ScanTile {
  /// Where this tile sits in the original photograph, in its pixels.
  final Rect region;

  /// True for the single pass over the entire image.
  final bool isWholeImage;

  const ScanTile(this.region, {this.isWholeImage = false});
}

/// The passes to run over a [width] x [height] photograph.
///
/// Always the whole image first. Tiles are added only when the photo is big
/// enough for them to add detail -- below [minTileSide] pixels on the short
/// side a quarter of the image holds no more information than the whole
/// image already gave the model, so tiling would only cost time.
///
/// Tiles overlap by [overlap] of their own size so a defect straddling the
/// middle of the photo is whole in at least one of them.
List<ScanTile> planScanTiles({
  required int width,
  required int height,
  int grid = 2,
  double overlap = 0.25,
  int minTileSide = 900,
}) {
  final tiles = <ScanTile>[
    ScanTile(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      isWholeImage: true,
    ),
  ];

  if (width <= 0 || height <= 0 || grid < 2) return tiles;

  // Each tile covers 1/grid of the image plus its share of the overlap.
  final tileWidth = width / (grid - (grid - 1) * overlap);
  final tileHeight = height / (grid - (grid - 1) * overlap);

  if (math.min(tileWidth, tileHeight) < minTileSide) return tiles;

  final stepX = tileWidth * (1 - overlap);
  final stepY = tileHeight * (1 - overlap);

  for (var row = 0; row < grid; row++) {
    for (var col = 0; col < grid; col++) {
      final left = math.min(col * stepX, width - tileWidth);
      final top = math.min(row * stepY, height - tileHeight);

      tiles.add(
        ScanTile(
          Rect.fromLTWH(
            left.roundToDouble(),
            top.roundToDouble(),
            tileWidth.roundToDouble(),
            tileHeight.roundToDouble(),
          ),
        ),
      );
    }
  }

  return tiles;
}

/// A detection already mapped back into the original photograph.
class PlacedDetection {
  final Rect box;
  final int classIndex;
  final double score;

  /// How many passes reported this same defect. A defect found by the whole
  /// image *and* by a tile is more trustworthy than one seen once.
  final int support;

  const PlacedDetection({
    required this.box,
    required this.classIndex,
    required this.score,
    this.support = 1,
  });

  PlacedDetection copyWith({Rect? box, double? score, int? support}) =>
      PlacedDetection(
        box: box ?? this.box,
        classIndex: classIndex,
        score: score ?? this.score,
        support: support ?? this.support,
      );
}

/// Merges the findings of every pass into one list of distinct defects.
///
/// Three kinds of duplicate have to go, or the count is wrong:
///
/// 1. **The same defect seen by two passes** -- the whole image and a tile,
///    or two overlapping tiles. Same class, overlapping boxes.
/// 2. **A box inside a box.** The model often boxes one knot twice, tightly
///    and loosely. IoU misses this; [intersectionOverSmaller] does not.
/// 3. **One defect given two names.** A dark knot with a check running out
///    of it can come back as both "Knot" and "Crack" on nearly the same box.
///    That is one thing on the log, so only the more confident label stays.
///
/// Survivors are grown to cover what they absorbed (so a crack found in two
/// halves by two tiles is reported whole), and their score is the best of the
/// group, nudged up slightly for every extra pass that agreed.
List<PlacedDetection> mergeDetections(
  List<PlacedDetection> detections, {
  double sameClassIou = 0.4,
  double sameClassContainment = 0.5,
  double crossClassIou = 0.6,
  double crossClassContainment = 0.85,
  int maxResults = 40,
}) {
  if (detections.isEmpty) return const [];

  final sorted = [...detections]..sort((a, b) => b.score.compareTo(a.score));
  final used = List<bool>.filled(sorted.length, false);
  final merged = <PlacedDetection>[];

  for (var i = 0; i < sorted.length; i++) {
    if (used[i]) continue;
    used[i] = true;

    var keep = sorted[i];
    var box = keep.box;
    var support = keep.support;

    for (var j = i + 1; j < sorted.length; j++) {
      if (used[j]) continue;

      final other = sorted[j];
      final iou = _iou(keep.box, other.box);
      final ios = intersectionOverSmaller(keep.box, other.box);

      final sameClass = other.classIndex == keep.classIndex;

      final duplicate = sameClass
          ? (iou >= sameClassIou || ios >= sameClassContainment)
          : (iou >= crossClassIou || ios >= crossClassContainment);

      if (!duplicate) continue;

      used[j] = true;

      if (sameClass) {
        // Only grow toward a box that genuinely overlaps; a small box wholly
        // inside this one adds nothing, and a union with a loose outlier
        // would balloon the box past the defect.
        final union = box.expandToInclude(other.box);
        final growth = (union.width * union.height) /
            math.max(box.width * box.height, 1e-9);

        if (growth <= 1.8) box = union;
        support += other.support;
      }
    }

    // A small, bounded reward for agreement. Never above 1, and never enough
    // to lift noise over the line on repetition alone.
    final boosted = math.min(
      1.0,
      keep.score + 0.04 * (support - 1).clamp(0, 3),
    );

    merged.add(keep.copyWith(box: box, score: boosted, support: support));
  }

  merged.sort((a, b) => b.score.compareTo(a.score));

  return merged.length > maxResults ? merged.sublist(0, maxResults) : merged;
}

/// Drops boxes too small to be a real defect at this resolution.
///
/// A box a few pixels across on a 12-megapixel photo is sensor noise or a
/// speck of sawdust, and every one that survives adds one to a count the
/// user is going to hold the app to.
List<PlacedDetection> dropSpecks(
  List<PlacedDetection> detections, {
  required int imageWidth,
  required int imageHeight,
  double minSideFraction = 0.006,
}) {
  final minSide =
      math.max(4.0, math.min(imageWidth, imageHeight) * minSideFraction);

  return [
    for (final d in detections)
      if (d.box.width >= minSide && d.box.height >= minSide) d,
  ];
}
