import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/models/log_measurement.dart';
import 'package:smartlog2/screens/log_scan_screen.dart';
import 'package:smartlog2/services/measurement_source.dart';
import 'package:smartlog2/services/user_preferences_service.dart';

import 'support/async_pump.dart';

/// Returns whatever measurement the test wants, without any sensor or UI.
/// This is the whole point of the [MeasurementSource] abstraction -- it
/// makes the entire scan screen drivable on a machine with no device.
class _FakeSource implements MeasurementSource {
  LogMeasurement? next;
  int measureCallCount = 0;

  _FakeSource(this.next);

  @override
  String get label => "Fake sensor";

  @override
  String get actionLabel => "Measure Log";

  @override
  List<String> get guidance => const ["Point at the log."];

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<LogMeasurement?> measure(BuildContext context) async {
    measureCallCount++;
    return next;
  }
}

LogMeasurement _lidarMeasurement({
  double diameter = 14,
  double length = 10,
  double? tolerance = 0.1,
  double? angularSpan = 170,
  int crossSections = 20,
}) {
  return LogMeasurement(
    minDiameterInches: diameter,
    lengthFeet: length,
    source: MeasurementSourceKind.lidar,
    diameterToleranceInches: tolerance,
    minAngularSpanDegrees: angularSpan,
    crossSectionCount: crossSections,
    diameterProfileInches: const [14.8, 14.2, 14.0, 14.5],
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UserPreferencesService.instance.resetForTesting();

    // Each test needs a genuinely separate database. Changing the path is
    // not enough on its own -- the open connection is cached statically, so
    // it has to be dropped too or every test shares the first one's data.
    await LocalDB.resetForTesting();
    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_scan_flow_${DateTime.now().microsecondsSinceEpoch}.db",
    );
  });

  testWidgets(
    'standalone: choose no stack, measure, and save the log',
    (tester) async {
      final source = _FakeSource(_lidarMeasurement());

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LogScanScreen(source: source)),
        );

        // The user is asked about a stack before measuring anything.
        await pumpUntilFound(tester, find.text("Start a Stack?"));

        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));
        await pumpUntilGone(tester, find.text("Start a Stack?"));

        expect(find.text("Measure Log"), findsOneWidget);

        await tester.tap(find.text("Measure Log"));
        await pumpUntilFound(tester, find.text("Measured Log"));

        expect(source.measureCallCount, 1);
        expect(find.text("Good"), findsOneWidget);
        // Diameter is shown with its uncertainty band, not as a bare number.
        expect(find.textContaining("±"), findsOneWidget);

        await tester.tap(find.text("Save Log"));
        // Result card is cleared and the screen is ready for the next log.
        await pumpUntilGone(tester, find.text("Measured Log"));

        expect(find.text("Log saved."), findsOneWidget);

        final saved = await LocalDB.getStandaloneLogs();
        expect(saved.length, 1);
        expect(saved.first["measurementSource"], "lidar");
        expect(saved.first["measurementQuality"], "good");
        expect(saved.first["diameterProfile"], isNotNull);
      });
    },
  );

  testWidgets(
    'stack: creating a stack accumulates running totals in the bottom bar',
    (tester) async {
      final source = _FakeSource(_lidarMeasurement(diameter: 12, length: 8));

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LogScanScreen(source: source)),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));

        // No stacks exist yet, so the sheet opens straight on "new stack".
        // Target the sheet's field explicitly: the scan screen underneath
        // also has a TextField (price), and it comes first in the tree.
        await tester.enterText(
          find.widgetWithText(TextField, "New Stack Name"),
          "Yard A",
        );
        await tester.pump();

        await tester.tap(find.text("Create Stack"));

        // The stack is now active, shown in the bottom bar.
        await pumpUntilFound(tester, find.text("Yard A"));
        await pumpUntilGone(tester, find.text("Create Stack"));
        expect(find.text("Saving logs individually"), findsNothing);

        await tester.tap(find.text("Measure Log"));
        await pumpUntilFound(tester, find.text("Add to Stack"));

        await tester.tap(find.text("Add to Stack"));

        // Bottom bar reflects the saved log.
        await pumpUntilFound(tester, find.textContaining("1 logs"));

        final stacks = await LocalDB.getStacks();
        expect(stacks.length, 1);
        expect((stacks.first["totalVolume"] as num).toDouble(),
            greaterThan(0));
      });
    },
  );

  testWidgets(
    'an unreliable measurement is refused rather than silently saved',
    (tester) async {
      // 70 degrees of visible arc is well below the usable threshold.
      final source = _FakeSource(_lidarMeasurement(angularSpan: 70));

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LogScanScreen(source: source)),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));

        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Measure Log"));

        await tester.tap(find.text("Measure Log"));
        await pumpUntilFound(tester, find.text("Unreliable"));

        await tester.tap(find.text("Save Log"));
        await pumpUntilFound(tester, find.text("Measurement Not Reliable"));

        await tester.tap(find.text("Close"));
        await pumpUntilGone(tester, find.text("Measurement Not Reliable"));

        // Nothing was written.
        final saved = await LocalDB.getStandaloneLogs();
        expect(saved, isEmpty);
      });
    },
  );

  testWidgets(
    'a borderline measurement requires explicit confirmation before saving',
    (tester) async {
      // Wide tolerance -> "fair", which warns rather than blocks.
      final source = _FakeSource(
        _lidarMeasurement(diameter: 14, tolerance: 0.5, angularSpan: 170),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LogScanScreen(source: source)),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));

        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Measure Log"));

        await tester.tap(find.text("Measure Log"));
        await pumpUntilFound(tester, find.text("Check"));

        await tester.tap(find.text("Save Log"));
        await pumpUntilFound(tester, find.text("Check This Measurement"));

        await tester.tap(find.text("Save Anyway"));
        await pumpUntilGone(tester, find.text("Measured Log"));

        final saved = await LocalDB.getStandaloneLogs();
        expect(saved.length, 1);
        expect(saved.first["measurementQuality"], "fair");
      });
    },
  );

  testWidgets(
    'the profile deduction is applied to the stored diameter and volume',
    (tester) async {
      final source = _FakeSource(_lidarMeasurement(diameter: 20, length: 10));

      await tester.runAsync(() async {
        await UserPreferencesService.instance.load();
        await UserPreferencesService.instance.setDiameterDeductionInches(2);

        await tester.pumpWidget(
          MaterialApp(home: LogScanScreen(source: source)),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));

        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Measure Log"));

        await tester.tap(find.text("Measure Log"));
        await pumpUntilFound(tester, find.text("Measured Log"));

        // The deduction is shown explicitly, not applied invisibly.
        expect(find.textContaining("After deduction"), findsOneWidget);

        await tester.tap(find.text("Save Log"));
        await pumpUntilGone(tester, find.text("Measured Log"));

        final saved = await LocalDB.getStandaloneLogs();
        expect(saved.length, 1);

        // Stored diameter is post-deduction, but the raw measurement and
        // the allowance are both retained for auditing.
        expect((saved.first["diameter"] as num).toDouble(), 18);
        expect((saved.first["rawDiameterInches"] as num).toDouble(), 20);
        expect((saved.first["deductionInches"] as num).toDouble(), 2);
      });
    },
  );
}
