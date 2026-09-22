import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/models/log_defect.dart';
import 'package:smartlog2/services/defect_advisor.dart';
import 'package:smartlog2/services/defect_detector.dart';
import 'package:smartlog2/services/defect_scan_controller.dart';
import 'package:smartlog2/screens/defect_detection_screen.dart';
import 'package:smartlog2/theme/app_theme.dart';

import 'support/async_pump.dart';

/// Stands in for the YOLO model: reports a fixed set of findings.
class _FakeDetector implements DefectDetector {
  final List<DefectFinding> findings;

  _FakeDetector(this.findings);

  @override
  String get name => "Fake detector";

  @override
  bool get isAvailable => true;

  @override
  Future<void> load() async {}

  @override
  Future<DefectAnalysis> analyse(
    img.Image image, {
    ScanProgress? onProgress,
  }) async {
    onProgress?.call(1, 1);
    return DefectAnalysis(findings: findings, passes: 1);
  }

  @override
  Future<List<LogDefect>> detect({required image, required outline}) async =>
      const [];

  @override
  void dispose() {}
}

/// A sharp, evenly lit texture big enough to pass the quality gate.
File _writePhoto(Directory dir) {
  final image = img.Image(width: 2000, height: 1500);

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final on = ((x ~/ 3) + (y ~/ 3)) % 2 == 0;
      final v = on ? 190 : 70;
      image.setPixelRgb(x, y, v, (v * 0.8).round(), (v * 0.6).round());
    }
  }

  return File("${dir.path}/log.jpg")
    ..writeAsBytesSync(img.encodeJpg(image, quality: 92));
}

final _findings = [
  const DefectFinding(
    kind: LogDefectKind.knot,
    rawLabel: "Knot",
    confidence: 0.82,
    region: Rect.fromLTWH(300, 300, 80, 80),
  ),
  const DefectFinding(
    kind: LogDefectKind.crack,
    rawLabel: "Crack",
    confidence: 0.71,
    region: Rect.fromLTWH(700, 200, 40, 500),
  ),
  // Faint: seen, but below the line the cutting engine acts on.
  const DefectFinding(
    kind: LogDefectKind.hollow,
    rawLabel: "Hole",
    confidence: 0.34,
    region: Rect.fromLTWH(1100, 800, 50, 50),
  ),
];

void main() {
  late Directory dir;
  late File photo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync("smartlog_scan_test");
    photo = _writePhoto(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('the count includes faint findings, and matches the photo',
      (tester) async {
    await tester.runAsync(() async {
      final scan = DefectScanController(
        detector: _FakeDetector(_findings),
        findFace: false,
      );

      await scan.scan(photo);

      expect(scan.phase, ScanPhase.done);

      // Every finding is drawn and every finding is counted. The old screen
      // drew three boxes and said "Found 2 defects".
      expect(scan.count, 3);
      expect(scan.marks(), hasLength(3));
      expect(scan.pendingCount, 1);

      // Only the clear ones reach the cutting engine until someone confirms.
      expect(scan.confirmedDefects, hasLength(2));

      scan.dispose();
    });
  });

  testWidgets('confirming and dismissing move the count and the grade',
      (tester) async {
    await tester.runAsync(() async {
      final scan = DefectScanController(
        detector: _FakeDetector(_findings),
        findFace: false,
      );

      await scan.scan(photo);

      // Confirm the faint hole: it now counts toward the cutting plan.
      scan.confirm(2);
      expect(scan.pendingCount, 0);
      expect(scan.confirmedDefects, hasLength(3));

      // "Not a defect": it leaves the count, and the photo shows a ghost.
      scan.dismiss(1);
      expect(scan.count, 2);
      expect(scan.dismissedCount, 1);
      expect(scan.marks().where((m) => m.dismissed), hasLength(1));
      expect(scan.breakdown.map((b) => b.label), isNot(contains("Crack")));

      // Undo brings it back as the scan first saw it.
      scan.restore(1);
      expect(scan.count, 3);

      // Dismiss everything: the face grades as clean.
      for (var i = 0; i < 3; i++) {
        scan.dismiss(i);
      }
      expect(scan.count, 0);
      expect(scan.grade.grade, LogGrade.prime);

      scan.dispose();
    });
  });

  testWidgets('suggestions are always there once a scan has run',
      (tester) async {
    await tester.runAsync(() async {
      final scan = DefectScanController(
        detector: _FakeDetector(_findings),
        findFace: false,
      );

      await scan.scan(photo);

      final advice = scan.advice();
      expect(advice, isNotEmpty);

      // The crack is the urgent one and comes first; the faint hole is
      // still flagged for a check by eye.
      expect(advice.first.priority, AdvicePriority.critical);
      expect(advice.map((a) => a.title).join(" "), contains("by eye"));

      scan.dispose();
    });
  });

  testWidgets('the screen shows the count, no percentages, and suggestions',
      (tester) async {
    await tester.runAsync(() async {
      final scan = DefectScanController(
        detector: _FakeDetector(_findings),
        findFace: false,
      );

      await scan.scan(photo);

      // Tall enough that the whole results list is on screen at once, so
      // "no percentages anywhere" really does check everything.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: DefectDetectionScreen(controller: scan, reviewOnly: true),
        ),
      );

      await pumpUntilFound(tester, find.text("defects found"));

      expect(find.text("3"), findsWidgets);

      // Not one percentage anywhere on the screen.
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? "")
          .where((t) => t.contains("%"));
      expect(texts, isEmpty);

      expect(find.text("What to do about it"), findsOneWidget);
      expect(find.text("Check by eye"), findsWidgets);
      expect(find.text("Not a defect"), findsWidgets);

      scan.dispose();
    });
  });

  testWidgets('with no photo the screen invites one', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: DefectDetectionScreen(
          controller: DefectScanController(
            detector: _FakeDetector(const []),
            findFace: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.textContaining("See every defect"), findsOneWidget);

    await tester.dragUntilVisible(
      find.text("Take or choose a photo"),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text("Take or choose a photo"), findsOneWidget);
  });
}
