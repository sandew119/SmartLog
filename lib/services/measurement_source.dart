import 'package:flutter/widgets.dart';

import '../models/log_measurement.dart';
import '../widgets/manual_measurement_sheet.dart';

/// Where a log's dimensions come from.
///
/// The scan screen depends on this rather than on any particular sensor, so
/// the same guided flow, settings, stack bar and save path work identically
/// whether the numbers arrive from iPhone LiDAR or are typed in on an
/// Android phone. It's also what makes the whole screen testable off-device
/// -- tests inject a fake source.
abstract class MeasurementSource {
  /// Shown to the user so they know how the log is being measured.
  String get label;

  /// Step-by-step tips shown before measuring. What makes a good
  /// measurement differs completely between a depth sensor and a tape, so
  /// the guidance belongs to the source rather than the screen.
  List<String> get guidance;

  /// Label for the button that starts a measurement.
  String get actionLabel;

  /// Whether this source can run on the current device right now. Must
  /// never throw -- an unavailable sensor is a normal condition.
  Future<bool> isSupported();

  /// Runs the measurement interaction. Returns null if the user cancelled.
  Future<LogMeasurement?> measure(BuildContext context);
}

/// Hand-entered dimensions. Always available, on every platform.
class ManualMeasurementSource implements MeasurementSource {
  /// Optional explanation shown at the top of the input sheet, e.g. why the
  /// app fell back to manual entry.
  final String? reason;

  const ManualMeasurementSource({this.reason});

  @override
  String get label => "Manual entry";

  @override
  String get actionLabel => "Enter Measurements";

  @override
  List<String> get guidance => const [
        "Measure the girth or diameter at the log's thinnest point.",
        "Measure the length along the log, end to end.",
        "Keep the tape square to the log so it isn't reading a diagonal.",
      ];

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<LogMeasurement?> measure(BuildContext context) {
    return showManualMeasurementSheet(context, reason: reason);
  }
}
