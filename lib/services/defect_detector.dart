import 'package:image/image.dart' as img;

import '../models/log_defect.dart';
import '../models/log_face_outline.dart';

/// Finds flaws on a log's cut face.
///
/// An interface with a deliberately boring implementation today. The point is
/// that everything downstream -- the toggle, the packing engine, the result
/// screen, the report -- is written against this now, so dropping in a real
/// model later is one line at the call site and changes nothing else.
///
/// The user-facing feature works from day one regardless, because defects
/// marked by hand and defects found by a model are the same [LogDefect] to
/// everything that consumes them.
abstract class DefectDetector {
  Future<List<LogDefect>> detect({
    required img.Image image,
    required LogFaceOutline outline,
  });
}

/// The current default: finds nothing, and says so honestly.
///
/// With this installed the "Consider defects" toggle still does real work,
/// because the defects the user taps on the face are fed to the engine
/// through the same path. It simply adds nothing of its own.
class NoAutomaticDefectDetector implements DefectDetector {
  const NoAutomaticDefectDetector();

  @override
  Future<List<LogDefect>> detect({
    required img.Image image,
    required LogFaceOutline outline,
  }) async =>
      const [];
}

/// Where a screen gets its detector from.
///
/// A single mutable seam rather than a constructor parameter threaded through
/// four widgets: when the model lands, this is the only line that changes,
/// and tests can swap in a fake without rebuilding the widget tree.
class DefectDetection {
  DefectDetection._();

  static DefectDetector instance = const NoAutomaticDefectDetector();

  /// True once something smarter than [NoAutomaticDefectDetector] is
  /// installed. The UI uses this to decide whether to offer automatic
  /// scanning at all, rather than showing a button that always finds nothing.
  static bool get isAutomaticAvailable =>
      instance is! NoAutomaticDefectDetector;

  static void reset() => instance = const NoAutomaticDefectDetector();
}
