import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/models/log_defect.dart';
import 'package:smartlog2/models/log_face_outline.dart';
import 'package:smartlog2/models/log_report.dart';
import 'package:smartlog2/models/sawing_models.dart';
import 'package:smartlog2/screens/log_report_builder_screen.dart';
import 'package:smartlog2/services/defect_advisor.dart';
import 'package:smartlog2/services/defect_impact.dart';
import 'package:smartlog2/services/log_report_pdf.dart';
import 'package:smartlog2/services/sawing_engine.dart';
import 'package:smartlog2/services/user_preferences_service.dart';
import 'package:smartlog2/theme/app_theme.dart';
import 'package:smartlog2/utils/timber_volume.dart';

import 'support/async_pump.dart';

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(180, 140, 90));
  return Uint8List.fromList(img.encodePng(image));
}

LogReportData _fullReport() {
  const setup = SawingSetup(
    logDiameterMm: 500,
    logLengthMm: 3000,
    boardThicknessMm: 50,
    boardWidthMm: 150,
    minBoardWidthMm: 75,
    kerfMm: 3,
    pricePerCubicFoot: 300,
  );

  final outline = LogFaceOutline.circle(500);

  const crack = LogDefect(
    kind: LogDefectKind.crack,
    centre: Offset(250, 250),
    radius: 60,
  );

  final comparison = SawingEngine.planBoth(
    setup.toRequest(outline, defects: const [crack], avoidDefects: true),
  );
  final sound = SawingEngine.planBoth(setup.toRequest(outline));

  final impacts = const DefectImpactAnalyser().analyse(
    outline: outline,
    defects: const [crack],
    setup: setup,
  );

  final defects = [
    AssessedDefect.locate(
      kind: LogDefectKind.crack,
      label: "Crack",
      region: const Rect.fromLTWH(480, 200, 40, 600),
      confirmed: true,
      imageSize: const Size(1000, 1000),
      faceCentre: const Offset(500, 500),
      faceRadius: 400,
    ),
    AssessedDefect.locate(
      kind: LogDefectKind.knot,
      label: "Knot",
      region: const Rect.fromLTWH(800, 450, 40, 40),
      confirmed: false,
      imageSize: const Size(1000, 1000),
      faceCentre: const Offset(500, 500),
      faceRadius: 400,
    ),
  ];

  return LogReportData(
    reference: "SL-260923-1432",
    createdAt: DateTime(2026, 9, 23, 14, 32),
    species: "Teak",
    notes: "From the north yard — “priority” order.",
    preparedBy: "Sandew",
    company: "Smart Timber (Pvt) Ltd",
    girthInches: 61.8,
    lengthFeet: 9.84,
    deductionInches: 1,
    volumeMethod: VolumeMethod.referenceTable,
    volume: TimberVolumeCalculator.calculate(
      method: VolumeMethod.referenceTable,
      girthInches: 60.8,
      lengthFeet: 9.84,
    ),
    cylinderCubicFeet: 20.5,
    ratePerCubicFoot: 2500,
    measurementSource: "Tape girth + traced photo",
    faceMajorInches: 20.1,
    faceMinorInches: 18.9,
    defects: defects,
    dismissedCount: 1,
    scanned: true,
    grade: LogQualityGrader.grade(defects),
    advice: DefectAdvisor.advise(defects: defects, hasTracedFace: true),
    defectImage: _png(400, 300),
    impacts: impacts,
    soundYieldCubicFeet: sound.best?.boardVolumeCubicFeet,
    actualYieldCubicFeet: comparison.best?.boardVolumeCubicFeet,
    comparison: comparison,
    setup: setup,
    plan: comparison.best,
    planAvoidsDefects: true,
    patternImage: _png(300, 300),
  );
}

void main() {
  group('Log Passport PDF', () {
    test('a full report renders to a PDF', () async {
      final bytes = await LogReportPdf.build(_fullReport());

      expect(bytes.length, greaterThan(2000));
      expect(String.fromCharCodes(bytes.take(4)), "%PDF");
    });

    test('a bare report -- measurements only -- still renders', () async {
      final data = LogReportData(
        reference: "SL-260923-0900",
        createdAt: DateTime(2026, 9, 23, 9),
        girthInches: 40,
        lengthFeet: 8,
        volumeMethod: VolumeMethod.standard,
        volume: TimberVolumeCalculator.calculate(
          method: VolumeMethod.standard,
          girthInches: 40,
          lengthFeet: 8,
        ),
        cylinderCubicFeet: 7.07,
        defects: const [],
        grade: LogQualityGrader.grade(const []),
        advice: const [],
        measurementSource: "Tape measure",
      );

      final bytes = await LogReportPdf.build(data);
      expect(String.fromCharCodes(bytes.take(4)), "%PDF");
    });
  });

  group('Log Passport figures', () {
    test('the loss is the sound yield less the actual one, never negative', () {
      final data = _fullReport();

      expect(data.hasImpact, isTrue);
      expect(data.lostCubicFeet, greaterThanOrEqualTo(0));
      expect(
        data.lostCubicFeet,
        closeTo(data.soundYieldCubicFeet! - data.actualYieldCubicFeet!, 1e-9),
      );
      expect(data.lostValue, closeTo(data.lostCubicFeet * 300, 1e-6));
    });

    test('the log value is the billed volume at the agreed rate', () {
      final data = _fullReport();
      expect(data.logValue, closeTo(data.volume.cubicFeetDecimal * 2500, 1e-6));
    });

    test('the breakdown puts the most serious kind first', () {
      final data = _fullReport();
      expect(data.defectBreakdown.first.label, "Crack");
    });

    test('references are short enough to chalk on a log end', () {
      final ref = LogReportData.newReference(DateTime(2026, 9, 23, 14, 32));
      expect(ref, "SL-260923-1432");
    });
  });

  group('builder', () {
    setUp(() => UserPreferencesService.instance.resetForTesting());

    testWidgets('girth and length alone produce a Log Passport',
        (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: const LogReportBuilderScreen(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 800));

        await tester.enterText(find.widgetWithText(TextField, "Girth"), "48");
        await tester.enterText(find.widgetWithText(TextField, "Length"), "10");
        await tester.pump();

        // The volume appears as soon as both numbers are in.
        expect(find.textContaining("adi"), findsWidgets);

        await tester.tap(find.text("Generate Log Passport"));

        await pumpUntilFound(tester, find.text("LOG PASSPORT"));

        expect(find.text("Export PDF"), findsOneWidget);
        // Never checked must never read as clean.
        expect(find.text("not scanned"), findsOneWidget);
      });
    });
  });
}
