import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Fractional bounding box (0..1 of image width/height) of the log's
/// detected outline, used only as a visual confirmation overlay during
/// capture — a single photo has no absolute scale, so this is never the
/// source of a physical measurement (LiDAR or manual entry is).
class LogBoundary {
  final double leftFraction;
  final double rightFraction;
  final double topFraction;
  final double bottomFraction;

  const LogBoundary({
    required this.leftFraction,
    required this.rightFraction,
    required this.topFraction,
    required this.bottomFraction,
  });
}

class LogEdgeDetector {
  static const double _edgeThreshold = 0.3;

  /// Runs basic Sobel edge detection on the captured photo to find the
  /// log's approximate boundary. Returns null if no confident boundary is
  /// found (e.g. poor lighting, no log in frame) — callers must treat that
  /// as "skip the overlay", not an error.
  static Future<LogBoundary?> detect(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    return compute(_detectSync, bytes);
  }

  static LogBoundary? _detectSync(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final small = img.copyResize(decoded, width: 300);
    final gray = img.grayscale(small);
    final edges = img.sobel(gray);

    final int w = edges.width;
    final int h = edges.height;

    final int midRow = h ~/ 2;
    final int midCol = w ~/ 2;

    int? left;
    int? right;
    int? top;
    int? bottom;

    for (int x = 0; x < w; x++) {
      if (edges.getPixel(x, midRow).luminanceNormalized > _edgeThreshold) {
        left = x;
        break;
      }
    }

    for (int x = w - 1; x >= 0; x--) {
      if (edges.getPixel(x, midRow).luminanceNormalized > _edgeThreshold) {
        right = x;
        break;
      }
    }

    for (int y = 0; y < h; y++) {
      if (edges.getPixel(midCol, y).luminanceNormalized > _edgeThreshold) {
        top = y;
        break;
      }
    }

    for (int y = h - 1; y >= 0; y--) {
      if (edges.getPixel(midCol, y).luminanceNormalized > _edgeThreshold) {
        bottom = y;
        break;
      }
    }

    if (left == null ||
        right == null ||
        top == null ||
        bottom == null ||
        right <= left ||
        bottom <= top) {
      return null;
    }

    return LogBoundary(
      leftFraction: left / w,
      rightFraction: right / w,
      topFraction: top / h,
      bottomFraction: bottom / h,
    );
  }
}
