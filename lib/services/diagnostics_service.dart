import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/local_db.dart';

/// Records why something failed, and how long things take.
///
/// Two requirements meet here for one reason: both answer questions that can
/// only be asked *after* the fact. A user in a timber yard reporting "it
/// didn't work yesterday" is useless without a store of what actually
/// happened, and a performance target is a claim rather than a measurement
/// until the timings are written down.
///
/// Never throws. A diagnostic layer that can break the operation it is
/// observing is worse than no diagnostic layer at all.
class DiagnosticsService {
  DiagnosticsService._();

  static final DiagnosticsService instance = DiagnosticsService._();

  static const String kindError = "error";
  static const String kindTiming = "timing";

  /// Modules, matching the failure classes the specification names.
  static const String moduleScan = "lidar_scan";
  static const String moduleDefects = "defect_detection";
  static const String moduleCutting = "cutting_optimisation";
  static const String moduleSync = "cloud_sync";
  static const String moduleReport = "report";

  Future<void> recordError({
    required String module,
    required Object error,
    String? code,
  }) async {
    // The raw exception is written here and never shown to the user, which
    // is exactly the split the requirement asks for: a readable message on
    // screen, the real trace in the store.
    debugPrint("[$module] $error");

    try {
      await LocalDB.recordDiagnostic(
        kind: kindError,
        module: module,
        code: code,
        message: "$error",
      );
    } catch (_) {}
  }

  Future<void> recordTiming({
    required String module,
    required int milliseconds,
    String? code,
  }) async {
    try {
      await LocalDB.recordDiagnostic(
        kind: kindTiming,
        module: module,
        code: code,
        durationMs: milliseconds,
      );
    } catch (_) {}
  }

  /// Runs [action], timing it, and records whichever way it ends.
  ///
  /// Wrapping rather than asking every call site to remember a stopwatch:
  /// the timing that gets forgotten is always the one that turns out to
  /// matter.
  Future<T> timed<T>(String module, Future<T> Function() action) async {
    final watch = Stopwatch()..start();

    try {
      final result = await action();
      watch.stop();

      await recordTiming(
          module: module, milliseconds: watch.elapsedMilliseconds);

      return result;
    } catch (error) {
      watch.stop();
      await recordError(module: module, error: error);
      rethrow;
    }
  }

  /// The 90th-percentile duration for a module, which is how the performance
  /// targets are stated -- a mean would hide exactly the slow runs the target
  /// exists to catch.
  Future<int?> percentile90(String module) async {
    try {
      final rows =
          await LocalDB.getDiagnostics(limit: LocalDB.diagnosticsLimit);

      final durations = <int>[
        for (final row in rows)
          if (row["kind"] == kindTiming &&
              row["module"] == module &&
              row["durationMs"] != null)
            row["durationMs"] as int,
      ]..sort();

      if (durations.isEmpty) return null;

      final index = ((durations.length - 1) * 0.9).round();
      return durations[index];
    } catch (_) {
      return null;
    }
  }
}
