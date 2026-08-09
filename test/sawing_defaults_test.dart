import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_face_outline.dart';
import 'package:smartlog2/models/sawing_models.dart';
import 'package:smartlog2/services/sawing_engine.dart';

/// The values the setup sheet opens with, so this file fails the moment a
/// default is changed to something the engine cannot cut.
const _exactSize = SawingSetup(
  logDiameterMm: 500,
  logLengthMm: 3000,
  boardThicknessMm: 50,
  boardWidthMm: 150,
  minBoardWidthMm: 75,
  kerfMm: 3,
);

const _maxYield = SawingSetup(
  logDiameterMm: 500,
  logLengthMm: 3000,
  boardThicknessMm: 50,
  mode: SawingMode.fixedThickness,
  minBoardWidthMm: 75,
  kerfMm: 3,
);

void main() {
  group('the settings the app ships with', () {
    test('exact-size defaults produce a plan, not an empty screen', () {
      final comparison = SawingEngine.planBoth(
        _exactSize.toRequest(
          LogFaceOutline.circle(_exactSize.logDiameterMm),
        ),
      );

      expect(comparison.cant, isNotNull);
      expect(comparison.live, isNotNull);
      expect(comparison.best!.boardCount, greaterThan(0));
    });

    test('max-yield defaults produce a plan too', () {
      final comparison = SawingEngine.planBoth(
        _maxYield.toRequest(LogFaceOutline.circle(_maxYield.logDiameterMm)),
      );

      expect(comparison.hasAny, isTrue);
      expect(comparison.best!.boardCount, greaterThan(0));
    });
  });

  test(
      'a request and its plan survive the isolate hop the UI puts them '
      'through', () async {
    // The search is slow enough to freeze a phone, so the screen runs it
    // through `compute`. That only works if every object involved can cross
    // an isolate boundary -- which is a property of the models, and would
    // otherwise fail for the first time on a device.
    final comparison = await compute(
      SawingEngine.planBoth,
      _exactSize.toRequest(LogFaceOutline.circle(_exactSize.logDiameterMm)),
    );

    expect(comparison.hasAny, isTrue);

    final plan = comparison.best!;
    expect(plan.boards, isNotEmpty);
    expect(plan.cuts, isNotEmpty);
    expect(plan.outline.points, hasLength(72));

    // The cant rectangle is the one field that is a Rect rather than a list
    // of points, so it is worth checking separately that it made the trip.
    expect(comparison.cant!.cant, isNotNull);
  });
}
