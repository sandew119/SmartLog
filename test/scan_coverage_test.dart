import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/scan_coverage.dart';

/// A sweep that satisfies everything, so each test can spoil one thing.
ScanProgress good({
  int pointCount = 40000,
  double length = 3.0,
  double angular = 260,
  double endFillStart = 0.6,
  double endFillEnd = 0.6,
  bool tracking = true,
  List<int> bins = const [8, 9, 10, 9, 8, 9, 10, 9],
}) {
  return ScanProgress(
    pointCount: pointCount,
    axisLengthMetres: length,
    angularCoverageDegrees: angular,
    endFillStart: endFillStart,
    endFillEnd: endFillEnd,
    axialBins: bins,
    trackingReliable: tracking,
  );
}

void main() {
  group('the scan is finished when the log has been seen', () {
    test('a full sweep is ready', () {
      expect(ScanCoverage(good()).isReady, isTrue);
      expect(ScanCoverage(good()).advice, ScanAdvice.readyToFinish);
    });

    test('an unseen far end is not ready, however good everything else is',
        () {
      // The failure the old code allowed: bounding-box extent stopped
      // growing, so the sweep ended, with a whole end of the log never
      // looked at.
      final coverage = ScanCoverage(good(endFillEnd: 0.05));

      expect(coverage.isReady, isFalse);
      expect(coverage.advice, ScanAdvice.showTheFarEnd);
      expect(coverage.message, contains("far end"));
    });

    test('an unseen near end is caught too', () {
      final coverage = ScanCoverage(good(endFillStart: 0.05));

      expect(coverage.isReady, isFalse);
      expect(coverage.advice, ScanAdvice.showTheNearEnd);
    });

    test('a thin arc round the trunk is refused', () {
      // One viewpoint sees 100-180 degrees. Fitting a circle to that is
      // ill-conditioned, and radius error squares into volume error.
      final coverage = ScanCoverage(good(angular: 150));

      expect(coverage.isReady, isFalse);
      expect(coverage.advice, ScanAdvice.goRoundTheSides);
    });

    test('a short object can still be finished', () {
      // The floor was 1.0 m, so nothing shorter could ever finish a scan:
      // the Finish button stayed dead however carefully the user swept, and
      // nothing on screen explained why. Whether the scan is trustworthy is
      // decided by what has been *seen* -- both ends, enough of the way
      // round, enough surface -- not by the object clearing a size the code
      // privately expects.
      expect(ScanCoverage(good(length: 0.5)).isReady, isTrue);
      expect(ScanCoverage(good(length: 0.2)).isReady, isTrue);
    });

    test('something too small for the sensor is still refused', () {
      expect(ScanCoverage(good(length: 0.03)).isReady, isFalse);
      expect(ScanCoverage(good(length: 0.03)).advice, ScanAdvice.walkTheLength);
    });

    test('a short object is not asked for a full log worth of points', () {
      // The point requirement scales with the surface there is to cover.
      // Held to a flat 25 000, a 20 cm sample can be swept perfectly and
      // still be told to move closer, for ever.
      expect(
        ScanCoverage.requiredPointsFor(0.2),
        lessThan(ScanCoverage.requiredPointsFor(3.0)),
      );

      expect(
        ScanCoverage.requiredPointsFor(3.0),
        ScanCoverage.maxPointRequirement,
        reason: "a full-size log must be asked for exactly what it always was",
      );
    });

    test('lost tracking outranks every other instruction', () {
      // No point asking someone to walk further when ARKit has lost its
      // place -- everything measured from here would be wrong anyway.
      final coverage = ScanCoverage(
        good(tracking: false, length: 0.2, endFillEnd: 0),
      );

      expect(coverage.advice, ScanAdvice.holdSteady);
      expect(coverage.isReady, isFalse);
    });

    test('nothing scanned yet asks the user to aim', () {
      expect(
        ScanCoverage(const ScanProgress()).advice,
        ScanAdvice.aimAtLog,
      );
    });

    test('ends are asked for before girth', () {
      // An unseen end caps the length, and length error is linear in volume.
      final coverage = ScanCoverage(good(angular: 120, endFillEnd: 0));

      expect(coverage.advice, ScanAdvice.showTheFarEnd);
    });
  });

  group('telling an end face from an unscanned stretch', () {
    test('a filled cross-section reads as an end', () {
      // A sawn face fills its disc; the curved trunk never does.
      expect(ScanCoverage(good(endFillStart: 0.6)).nearEndSeen, isTrue);
    });

    test('a ring of bark does not', () {
      // Mid-trunk the sensor only sees the curved surface, so points sit in
      // a ring and the middle of the disc is empty.
      expect(ScanCoverage(good(endFillStart: 0.08)).nearEndSeen, isFalse);
    });

    test('the threshold sits well clear of both cases', () {
      expect(ScanCoverage.endFillThreshold, greaterThan(0.15));
      expect(ScanCoverage.endFillThreshold, lessThan(0.6));
    });
  });

  group('completion', () {
    test('is the worst requirement, not the average', () {
      // Magnificent girth coverage with an end unseen is not a sweep that is
      // three-quarters finished. It is unfinished.
      final coverage = ScanCoverage(
        good(angular: 360, pointCount: 200000, endFillEnd: 0),
      );

      expect(coverage.completion, 0);
    });

    test('is 1 when everything is met', () {
      expect(ScanCoverage(good()).completion, 1.0);
    });

    test('nothing scanned is zero', () {
      expect(ScanCoverage(const ScanProgress()).completion, 0);
    });

    test('never exceeds 1 however much is scanned', () {
      final coverage = ScanCoverage(
        good(pointCount: 5000000, length: 40, angular: 720),
      );

      expect(coverage.completion, lessThanOrEqualTo(1.0));
    });
  });

  group('reading the native payload', () {
    test('a well-formed payload is read', () {
      final progress = ScanProgress.fromNative(const {
        "pointCount": 31000,
        "axisLengthMetres": 2.8,
        "angularCoverageDegrees": 240.0,
        "endFillStart": 0.55,
        "endFillEnd": 0.48,
        "axialBins": [4, 7, 9, 6],
        "trackingState": "normal",
      });

      expect(progress.pointCount, 31000);
      expect(progress.axisLengthMetres, 2.8);
      expect(progress.trackingReliable, isTrue);
      expect(progress.axialBins, [4, 7, 9, 6]);
    });

    test('missing fields default rather than throwing', () {
      // The native side is the least verified part of the app. A malformed
      // payload has to degrade the guidance, not crash a scan someone is
      // halfway through.
      final progress = ScanProgress.fromNative(const {});

      expect(progress.pointCount, 0);
      expect(progress.axisLengthMetres, 0);
      expect(progress.axialBins, isEmpty);
      expect(progress.trackingReliable, isFalse);
    });

    test('wrong types are ignored, not trusted', () {
      final progress = ScanProgress.fromNative(const {
        "pointCount": "lots",
        "axisLengthMetres": null,
        "axialBins": "not a list",
        "endFillStart": 5.0,
      });

      expect(progress.pointCount, 0);
      expect(progress.axisLengthMetres, 0);
      expect(progress.axialBins, isEmpty);

      // Out of range is clamped, so it cannot fake a finished scan.
      expect(progress.endFillStart, 1.0);
    });

    test('a non-finite number becomes zero', () {
      final progress = ScanProgress.fromNative(const {
        "axisLengthMetres": double.nan,
        "angularCoverageDegrees": double.infinity,
      });

      expect(progress.axisLengthMetres, 0);
      expect(progress.angularCoverageDegrees, 0);
    });

    test('anything but "normal" tracking is unreliable', () {
      for (final state in ["limited", "notAvailable", "unknown"]) {
        expect(
          ScanProgress.fromNative({"trackingState": state}).trackingReliable,
          isFalse,
          reason: state,
        );
      }
    });
  });

  group('the coverage bar', () {
    test('normalises against a high percentile, not the maximum', () {
      // One spot where the user lingered must not make everywhere else look
      // unscanned.
      final coverage = ScanCoverage(
        good(bins: const [10, 10, 10, 10, 10, 900]),
      );

      final bar = coverage.axialCoverage;

      expect(bar.first, 1.0);
      expect(bar.last, 1.0);
    });

    test('shows a thin section as thin', () {
      final coverage = ScanCoverage(
        good(bins: const [10, 10, 1, 10, 10]),
      );

      expect(coverage.axialCoverage[2], lessThan(0.3));
    });

    test('no bins is not a crash', () {
      expect(ScanCoverage(good(bins: const [])).axialCoverage, isEmpty);
    });

    test('all-empty bins report no coverage', () {
      expect(
        ScanCoverage(good(bins: const [0, 0, 0])).axialCoverage,
        [0, 0, 0],
      );
    });
  });

  group('the checklist the user reads', () {
    test('every requirement is listed with its state', () {
      final items = ScanCoverage(good(endFillEnd: 0)).checklist;

      expect(items, hasLength(5));
      expect(items.firstWhere((i) => i.label == "Far end").done, isFalse);
      expect(items.firstWhere((i) => i.label == "Near end").done, isTrue);
    });

    test('details are readable figures, not raw numbers', () {
      final items = ScanCoverage(good()).checklist;

      expect(items.firstWhere((i) => i.label == "Length").detail, "3.00 m");
      expect(
        items.firstWhere((i) => i.label == "Around the log").detail,
        "260°",
      );
    });
  });
}
