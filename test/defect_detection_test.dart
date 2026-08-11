import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/models/log_defect.dart';
import 'package:smartlog2/models/log_face_outline.dart';
import 'package:smartlog2/models/sawing_models.dart';
import 'package:smartlog2/services/defect_detector.dart';
import 'package:smartlog2/services/defect_impact.dart';
import 'package:smartlog2/services/tflite_defect_detector.dart';
import 'package:smartlog2/utils/image_quality.dart';

/// A flat grey image: no detail at all, so the Laplacian variance is zero.
img.Image _flat(int w, int h, int level) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(level, level, level));
  return image;
}

/// Fine checkerboard texture — the sharpest thing an image can be.
img.Image _sharp(int w, int h, {int light = 200, int dark = 40}) {
  final image = img.Image(width: w, height: h);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final on = ((x ~/ 2) + (y ~/ 2)) % 2 == 0;
      final v = on ? light : dark;
      image.setPixelRgb(x, y, v, v, v);
    }
  }

  return image;
}

void main() {
  group('image quality — refusing before inference', () {
    test('a sharp, well-lit photo passes', () {
      final quality = ImageQualityChecker.assess(
        _sharp(2000, 1500),
      );

      expect(quality.isUsable, isTrue);
      expect(quality.message, isNull);
    });

    test('a flat image is reported as blurred, not as a valid reading', () {
      // A model has no way to say "I cannot see" -- it returns a confident
      // answer for a photograph of nothing. This is the only place that
      // judgement can be made.
      final quality = ImageQualityChecker.assess(_flat(2000, 1500, 128));

      expect(quality.isUsable, isFalse);
      expect(quality.fault, ImageQualityFault.tooBlurred);
      expect(quality.message, contains("blurred"));
    });

    test('darkness is reported before blur', () {
      // A nearly-black photo also has no measurable detail, but "it is too
      // dark" is the thing the user can act on.
      final quality =
          ImageQualityChecker.assess(_sharp(2000, 1500, light: 20, dark: 0));

      expect(quality.fault, ImageQualityFault.tooDark);
      expect(quality.message, contains("light"));
    });

    test('a washed-out photo is caught', () {
      final quality = ImageQualityChecker.assess(
        _sharp(2000, 1500, light: 255, dark: 240),
      );

      expect(quality.fault, ImageQualityFault.tooBright);
    });

    test('a screenshot-sized image is rejected on resolution', () {
      final quality = ImageQualityChecker.assess(_sharp(640, 480));

      expect(quality.fault, ImageQualityFault.tooSmall);
      expect(quality.message, contains("screenshot"));
    });

    test('sharpness ranks a sharp image above a blurred one', () {
      final sharp = ImageQualityChecker.assess(_sharp(800, 600),
          enforceResolution: false);

      final blurred = ImageQualityChecker.assess(
        img.gaussianBlur(_sharp(800, 600), radius: 6),
        enforceResolution: false,
      );

      expect(sharp.sharpness, greaterThan(blurred.sharpness));
    });

    test('every message says what to change, never just "invalid"', () {
      for (final fault in ImageQualityFault.values) {
        final quality = ImageQuality(
          sharpness: 0,
          brightness: 0,
          width: 10,
          height: 10,
          fault: fault,
        );

        expect(quality.message, isNotNull);
        expect(quality.message!.toLowerCase(), isNot(contains("invalid")));
      }
    });
  });

  group('label mapping — the dataset speaks, the app translates', () {
    test('common defect names resolve', () {
      expect(DefectLabelMap.resolve("Knot"), LogDefectKind.knot);
      expect(DefectLabelMap.resolve("rot"), LogDefectKind.rot);
      expect(DefectLabelMap.resolve("Crack"), LogDefectKind.crack);
      expect(DefectLabelMap.resolve("wormhole"), LogDefectKind.hollow);
    });

    test('spacing and case do not matter', () {
      expect(DefectLabelMap.resolve("Dead Knot"), LogDefectKind.knot);
      expect(DefectLabelMap.resolve("blue-stain"), LogDefectKind.rot);
    });

    test('healthy labels are recognised as healthy', () {
      for (final label in ["Healthy", "normal", "no_defect", "sound"]) {
        expect(DefectLabelMap.isHealthy(label), isTrue, reason: label);
        expect(DefectLabelMap.resolve(label), isNull);
      }
    });

    test('a compound label takes the most serious term in it', () {
      // "dead_knot_with_crack" must not be filed as a plain knot.
      expect(
        DefectLabelMap.resolve("dead_knot_with_crack"),
        LogDefectKind.crack,
      );
    });

    test('an unrecognised label returns null rather than guessing', () {
      // Silently filing an unknown class under "knot" would let a mapping
      // mistake reach a cutting plan disguised as a real finding.
      expect(DefectLabelMap.resolve("quokka"), isNull);
      expect(DefectLabelMap.resolve(""), isNull);
    });
  });

  group('the four classes this model was trained on', () {
    // crack, hole, knot, clear -- listed alphabetically in the labels asset
    // because that is the order Keras assigns from folder names.
    test('each maps onto the app vocabulary', () {
      expect(DefectLabelMap.resolve("crack"), LogDefectKind.crack);
      expect(DefectLabelMap.resolve("hole"), LogDefectKind.hollow);
      expect(DefectLabelMap.resolve("knot"), LogDefectKind.knot);

      // "clear" means sound timber, not a defect.
      expect(DefectLabelMap.isHealthy("clear"), isTrue);
      expect(DefectLabelMap.resolve("clear"), isNull);
    });

    test('hole and crack block boards; a knot does not', () {
      LogDefect defect(LogDefectKind kind) =>
          LogDefect(kind: kind, centre: Offset.zero, radius: 10);

      expect(defect(LogDefectKind.hollow).isDisqualifying, isTrue);
      expect(defect(LogDefectKind.crack).isDisqualifying, isTrue);
      expect(defect(LogDefectKind.knot).isDisqualifying, isFalse);
    });
  });

  group('softmax, for a retrained model that emits logits', () {
    test('turns logits into probabilities that sum to one', () {
      final p = softmax([2.0, 1.0, 0.1, -1.0]);

      expect(p.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
      expect(p.first, greaterThan(p.last));
    });

    test('large logits do not overflow', () {
      // Subtracting the peak before exponentiating is what stops this
      // becoming NaN -- and a NaN confidence sails past the 0.60 threshold
      // comparison as false, silently disabling every finding.
      final p = softmax([1000.0, 999.0]);

      expect(p.every((v) => v.isFinite), isTrue);
      expect(p.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
    });

    test('an empty input is not a crash', () {
      expect(softmax(const []), isEmpty);
    });
  });

  group('findings', () {
    DefectFinding finding(double confidence, {bool healthy = false}) =>
        DefectFinding(
          kind: LogDefectKind.rot,
          rawLabel: "rot",
          confidence: confidence,
          region: const Rect.fromLTWH(10, 10, 40, 40),
          isHealthy: healthy,
        );

    test('the 0.60 threshold decides what is acted on', () {
      expect(finding(0.59).isConfident, isFalse);
      expect(finding(0.60).isConfident, isTrue);
    });

    test('an uncertain analysis is not the same as a clean one', () {
      final uncertain = DefectAnalysis(findings: [finding(0.3)]);

      // "I looked and it is fine" and "I saw something but am not sure"
      // must not appear the same to the user.
      expect(uncertain.isClean, isFalse);
      expect(uncertain.isUncertain, isTrue);
      expect(uncertain.actionable, isEmpty);
    });

    test('a healthy finding reads as clean', () {
      final clean = DefectAnalysis(findings: [finding(0.95, healthy: true)]);

      expect(clean.isClean, isTrue);
      expect(clean.isUncertain, isFalse);
    });

    test('a box becomes a circle that covers it', () {
      final defect = finding(0.9).toDefect();

      expect(defect.centre, const Offset(30, 30));
      // Generous on purpose: a board clipping the edge of a rotten patch is
      // not a board anyone wants.
      expect(defect.radius, 20);
      expect(defect.automatic, isTrue);
    });
  });

  group('impact — what a defect actually costs this log', () {
    final outline = LogFaceOutline.circle(500);

    const setup = SawingSetup(
      logDiameterMm: 500,
      logLengthMm: 3000,
      boardThicknessMm: 50,
      boardWidthMm: 150,
      minBoardWidthMm: 75,
      kerfMm: 3,
      pricePerCubicFoot: 250,
    );

    LogDefect at(Offset centre, double radius, LogDefectKind kind) =>
        LogDefect(kind: kind, centre: centre, radius: radius);

    test('rot in the middle costs more than rot at the edge', () {
      final middle = const DefectImpactAnalyser()
          .analyse(
            outline: outline,
            defects: [at(const Offset(250, 250), 70, LogDefectKind.rot)],
            setup: setup,
          )
          .single;

      final edge = const DefectImpactAnalyser()
          .analyse(
            outline: outline,
            defects: [at(const Offset(465, 250), 25, LogDefectKind.rot)],
            setup: setup,
          )
          .single;

      // This is the whole point of the analysis: the same defect, the same
      // confidence, and two completely different prices.
      expect(middle.lostCubicFeet, greaterThan(edge.lostCubicFeet));
    });

    test('a costly defect is priced when a rate is given', () {
      final impact = const DefectImpactAnalyser()
          .analyse(
            outline: outline,
            defects: [at(const Offset(250, 250), 80, LogDefectKind.rot)],
            setup: setup,
          )
          .single;

      if (impact.lostCubicFeet > 0) {
        expect(impact.lostValue, greaterThan(0));
        expect(impact.explanation, contains("Rs."));
      }
    });

    test('rot blocks boards, a knot does not', () {
      final rot = const DefectImpactAnalyser()
          .analyse(
            outline: outline,
            defects: [at(const Offset(250, 250), 40, LogDefectKind.rot)],
            setup: setup,
          )
          .single;

      final knot = const DefectImpactAnalyser()
          .analyse(
            outline: outline,
            defects: [at(const Offset(250, 250), 40, LogDefectKind.knot)],
            setup: setup,
          )
          .single;

      expect(rot.blocksBoards, isTrue);
      expect(knot.blocksBoards, isFalse);

      expect(rot.explanation, contains("wood that isn't there"));
      expect(knot.explanation, contains("lower grade"));
    });

    test('severity weighs the kind and the size together', () {
      // A pinhole of rot is not a high-severity log...
      final tiny = DefectImpactAnalyser.severityOf(
        at(Offset.zero, 1, LogDefectKind.rot),
        0.0001,
      );

      // ...and a knot over a third of the face is not a low-severity one.
      final bigKnot = DefectImpactAnalyser.severityOf(
        at(Offset.zero, 100, LogDefectKind.knot),
        0.35,
      );

      expect(tiny.index, lessThan(DefectSeverity.high.index));
      expect(bigKnot.index, greaterThan(DefectSeverity.low.index));
    });

    test('two defects never claim more loss than the log holds', () {
      final impacts = const DefectImpactAnalyser().analyse(
        outline: outline,
        defects: [
          at(const Offset(230, 250), 60, LogDefectKind.rot),
          at(const Offset(270, 250), 60, LogDefectKind.rot),
        ],
        setup: setup,
      );

      final total = impacts.fold<double>(0, (s, i) => s + i.lostCubicFeet);

      expect(total, lessThanOrEqualTo(impacts.first.yieldIfSoundCubicFeet));
    });

    test('the summary names the count and the worst severity', () {
      final impacts = const DefectImpactAnalyser().analyse(
        outline: outline,
        defects: [
          at(const Offset(250, 250), 40, LogDefectKind.rot),
          at(const Offset(180, 200), 20, LogDefectKind.knot),
        ],
        setup: setup,
      );

      final summary = DefectImpactAnalyser.summarise(impacts);

      expect(summary, contains("2 defects"));
      expect(summary, contains("severity"));
    });

    test('no defects, nothing to say', () {
      expect(
        DefectImpactAnalyser.summarise(const []),
        contains("No defects"),
      );
    });
  });

  group('the default detector is honest about doing nothing', () {
    test('it reports itself unavailable rather than finding nothing', () async {
      const detector = NoAutomaticDefectDetector();

      // "It found nothing" and "nothing is looking" must never look the same
      // to the user.
      expect(detector.isAvailable, isFalse);
      expect(detector.name, contains("No model"));

      final analysis = await detector.analyse(_flat(10, 10, 128));
      expect(analysis.findings, isEmpty);
    });

    test('DefectDetection reflects what is installed', () {
      DefectDetection.reset();
      expect(DefectDetection.isAutomaticAvailable, isFalse);
    });
  });

  test('sanity: a circle outline has the area we assume', () {
    final outline = LogFaceOutline.circle(500);
    expect(
        outline.area, closeTo(math.pi * 250 * 250, math.pi * 250 * 250 * 0.02));
  });
}
