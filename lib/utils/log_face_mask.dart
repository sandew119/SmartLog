import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import '../models/log_face_outline.dart';

/// A log face rasterised once, so "does this board fit?" becomes O(1).
///
/// The sawing search asks that question hundreds of thousands of times --
/// every angle, every cant size, every offset. Answering it by walking the
/// polygon each time ([LogFaceOutline.containsRect]) is far too slow to
/// search properly, which is why the old engine could only afford a coarse
/// grid. Rasterising the face once and building a summed-area table makes
/// each test a constant four array lookups, and buys back enough budget to
/// search the space that actually matters.
///
/// Cells are marked usable only when the cell *and all its neighbours* are
/// inside the outline. That erosion makes the mask deliberately pessimistic:
/// a rectangle this class accepts genuinely fits, and the error is always in
/// the direction of leaving a little timber on the table rather than
/// promising a board that will not cut.
class LogFaceMask {
  final int cols;
  final int rows;

  /// Width of one cell, in the outline's own units.
  final double cellSize;

  /// World position of the (0,0) cell's corner.
  final Offset origin;

  /// Summed-area table over the eroded mask, `(cols + 1) * (rows + 1)`.
  final Int32List _integral;

  final int usableCells;

  const LogFaceMask._({
    required this.cols,
    required this.rows,
    required this.cellSize,
    required this.origin,
    required Int32List integral,
    required this.usableCells,
  }) : _integral = integral;

  /// Rasterises [outline]. [resolution] is the cell count along the longer
  /// side; 256 over a 500 mm log is roughly 2 mm per cell, comfortably finer
  /// than a saw kerf.
  static LogFaceMask? fromOutline(
    LogFaceOutline outline, {
    int resolution = 256,
  }) {
    if (!outline.isValid || resolution < 8) return null;

    final bounds = outline.bounds;
    final longest = math.max(bounds.width, bounds.height);
    if (longest <= 0 || !longest.isFinite) return null;

    final cellSize = longest / resolution;
    if (cellSize <= 0) return null;

    // One cell of margin so the erosion below has something to erode into
    // rather than clipping against the array edge.
    final origin = Offset(bounds.left - cellSize, bounds.top - cellSize);

    final cols = (bounds.width / cellSize).ceil() + 2;
    final rows = (bounds.height / cellSize).ceil() + 2;

    if (cols < 3 || rows < 3) return null;

    // Pass 1: is each cell's centre inside the polygon?
    final raw = Uint8List(cols * rows);

    for (var r = 0; r < rows; r++) {
      final y = origin.dy + (r + 0.5) * cellSize;

      for (var c = 0; c < cols; c++) {
        final x = origin.dx + (c + 0.5) * cellSize;

        if (outline.contains(Offset(x, y))) {
          raw[r * cols + c] = 1;
        }
      }
    }

    // Pass 2: erode. A centre-inside test says nothing about the cell's
    // corners, so a cell on the boundary can be half outside. Requiring all
    // eight neighbours too means an accepted cell is wholly within the face.
    final eroded = Uint8List(cols * rows);
    var usable = 0;

    for (var r = 1; r < rows - 1; r++) {
      for (var c = 1; c < cols - 1; c++) {
        if (raw[r * cols + c] == 0) continue;

        var solid = true;
        for (var dr = -1; dr <= 1 && solid; dr++) {
          for (var dc = -1; dc <= 1; dc++) {
            if (raw[(r + dr) * cols + (c + dc)] == 0) {
              solid = false;
              break;
            }
          }
        }

        if (solid) {
          eroded[r * cols + c] = 1;
          usable++;
        }
      }
    }

    // Pass 3: summed-area table, offset by one row and column so the
    // inclusion-exclusion lookup never needs a bounds check.
    final integral = Int32List((cols + 1) * (rows + 1));

    for (var r = 0; r < rows; r++) {
      var rowSum = 0;
      for (var c = 0; c < cols; c++) {
        rowSum += eroded[r * cols + c];
        integral[(r + 1) * (cols + 1) + (c + 1)] =
            integral[r * (cols + 1) + (c + 1)] + rowSum;
      }
    }

    return LogFaceMask._(
      cols: cols,
      rows: rows,
      cellSize: cellSize,
      origin: origin,
      integral: integral,
      usableCells: usable,
    );
  }

  /// Area the mask considers usable. Slightly under the outline's true area
  /// because of the erosion -- that gap is the safety margin.
  double get usableArea => usableCells * cellSize * cellSize;

  int _sum(int c0, int r0, int c1, int r1) {
    final w = cols + 1;
    return _integral[(r1 + 1) * w + (c1 + 1)] -
        _integral[r0 * w + (c1 + 1)] -
        _integral[(r1 + 1) * w + c0] +
        _integral[r0 * w + c0];
  }

  /// True when every cell the rectangle touches is usable.
  bool containsRect(Rect rect) {
    if (rect.width <= 0 || rect.height <= 0) return false;
    if (!rect.left.isFinite || !rect.top.isFinite) return false;
    if (!rect.right.isFinite || !rect.bottom.isFinite) return false;

    final c0 = ((rect.left - origin.dx) / cellSize).floor();
    final r0 = ((rect.top - origin.dy) / cellSize).floor();
    final c1 = ((rect.right - origin.dx) / cellSize).floor();
    final r1 = ((rect.bottom - origin.dy) / cellSize).floor();

    if (c0 < 0 || r0 < 0 || c1 >= cols || r1 >= rows) return false;
    if (c1 < c0 || r1 < r0) return false;

    final cellCount = (c1 - c0 + 1) * (r1 - r0 + 1);

    return _sum(c0, r0, c1, r1) == cellCount;
  }

  /// Widest rectangle of full height that fits in the horizontal band
  /// between [top] and [bottom].
  ///
  /// This is the heart of live sawing: a slab is cut right through the log,
  /// and the board that eventually comes off it -- once the waney edges are
  /// trimmed -- is the widest rectangle spanning the slab's full thickness.
  /// Returns null when nothing usable spans the band.
  ({double left, double right})? widestRunInBand(double top, double bottom) {
    if (bottom <= top) return null;

    final r0 = ((top - origin.dy) / cellSize).floor();
    final r1 = ((bottom - origin.dy) / cellSize).floor();

    if (r0 < 0 || r1 >= rows || r1 < r0) return null;

    final bandRows = r1 - r0 + 1;

    var bestStart = -1;
    var bestLength = 0;

    var runStart = -1;

    for (var c = 0; c < cols; c++) {
      // A column counts only if it is usable through the whole band -- a
      // board cannot be thinner in the middle than at its edges.
      final full = _sum(c, r0, c, r1) == bandRows;

      if (full) {
        if (runStart < 0) runStart = c;

        final length = c - runStart + 1;
        if (length > bestLength) {
          bestLength = length;
          bestStart = runStart;
        }
      } else {
        runStart = -1;
      }
    }

    if (bestStart < 0 || bestLength <= 0) return null;

    return (
      left: origin.dx + bestStart * cellSize,
      right: origin.dx + (bestStart + bestLength) * cellSize,
    );
  }

  /// Largest rectangle of the given [aspectHeight] that fits, searched over
  /// candidate widths. Used to size a cant.
  ///
  /// Returns null when nothing of that height fits at all.
  Rect? widestRectOfHeight(double height, {int verticalSteps = 64}) {
    if (height <= 0) return null;

    final worldTop = origin.dy;
    final worldBottom = origin.dy + rows * cellSize;

    final span = worldBottom - worldTop - height;
    if (span < 0) return null;

    Rect? best;

    for (var i = 0; i <= verticalSteps; i++) {
      final top = worldTop + span * i / verticalSteps;
      final run = widestRunInBand(top, top + height);
      if (run == null) continue;

      final candidate = Rect.fromLTRB(run.left, top, run.right, top + height);

      if (best == null || candidate.width > best.width) {
        best = candidate;
      }
    }

    return best;
  }
}
