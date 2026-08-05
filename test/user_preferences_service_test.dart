import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartlog2/services/user_preferences_service.dart';
import 'package:smartlog2/utils/timber_volume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = UserPreferencesService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service.resetForTesting();
  });

  group('defaults', () {
    test('a fresh install gets the standard method and no deduction', () async {
      final prefs = await service.load();

      expect(prefs.volumeMethod, VolumeMethod.standard);
      expect(prefs.diameterDeductionInches, 0);
    });
  });

  group('round-trip', () {
    test('a saved volume method survives a reload', () async {
      await service.load();
      await service.setVolumeMethod(VolumeMethod.referenceTable);

      service.resetForTesting();
      final reloaded = await service.load();

      expect(reloaded.volumeMethod, VolumeMethod.referenceTable);
    });

    test('a saved deduction survives a reload', () async {
      await service.load();
      await service.setDiameterDeductionInches(1.5);

      service.resetForTesting();
      final reloaded = await service.load();

      expect(reloaded.diameterDeductionInches, 1.5);
    });

    test('setting one preference does not clobber the other', () async {
      await service.load();
      await service.setVolumeMethod(VolumeMethod.referenceTable);
      await service.setDiameterDeductionInches(2.5);

      service.resetForTesting();
      final reloaded = await service.load();

      expect(reloaded.volumeMethod, VolumeMethod.referenceTable);
      expect(reloaded.diameterDeductionInches, 2.5);
    });
  });

  group('corrupt or hostile stored values', () {
    test('an unrecognised stored method falls back to standard', () async {
      SharedPreferences.setMockInitialValues({
        "flutter.volume_method": "some_method_from_a_future_version",
      });

      final prefs = await service.load();

      // Must not throw -- a corrupt value should never lock the user out of
      // their own settings screen.
      expect(prefs.volumeMethod, VolumeMethod.standard);
    });

    test('a negative stored deduction loads as zero', () async {
      SharedPreferences.setMockInitialValues({
        "flutter.diameter_deduction_inches": -4.0,
      });

      final prefs = await service.load();
      expect(prefs.diameterDeductionInches, 0);
    });

    test('an absurd stored deduction is clamped to the maximum', () async {
      SharedPreferences.setMockInitialValues({
        "flutter.diameter_deduction_inches": 500.0,
      });

      final prefs = await service.load();
      expect(
        prefs.diameterDeductionInches,
        UserPreferencesService.maxDeductionInches,
      );
    });
  });

  group('input sanitising on write', () {
    test('rejects NaN and infinity, storing zero', () async {
      await service.load();

      await service.setDiameterDeductionInches(double.nan);
      expect(service.current.diameterDeductionInches, 0);

      await service.setDiameterDeductionInches(double.infinity);
      expect(service.current.diameterDeductionInches, 0);
    });

    test('clamps an over-large deduction on write', () async {
      await service.load();
      await service.setDiameterDeductionInches(99);

      expect(
        service.current.diameterDeductionInches,
        UserPreferencesService.maxDeductionInches,
      );
    });
  });

  group('listenable', () {
    test('notifies listeners when a preference changes', () async {
      await service.load();

      final seen = <UserPreferences>[];
      void listener() => seen.add(service.current);

      service.listenable.addListener(listener);
      addTearDown(() => service.listenable.removeListener(listener));

      await service.setVolumeMethod(VolumeMethod.referenceTable);
      await service.setDiameterDeductionInches(1);

      expect(seen.length, 2);
      expect(seen.last.volumeMethod, VolumeMethod.referenceTable);
      expect(seen.last.diameterDeductionInches, 1);
    });
  });

  group('cloud mirroring', () {
    test('invokes the sync callback with the updated preferences', () async {
      await service.load();

      final pushed = <UserPreferences>[];
      service.syncCallback = (prefs) async => pushed.add(prefs);

      await service.setVolumeMethod(VolumeMethod.referenceTable);

      expect(pushed.single.volumeMethod, VolumeMethod.referenceTable);
    });

    test('a failing cloud push never breaks the local save', () async {
      await service.load();
      service.syncCallback = (_) async => throw Exception("offline");

      // Must complete normally -- the local value is the source of truth.
      await service.setDiameterDeductionInches(2);

      expect(service.current.diameterDeductionInches, 2);

      service.resetForTesting();
      final reloaded = await service.load();
      expect(reloaded.diameterDeductionInches, 2);
    });

    test('does nothing when no sync callback is installed (guest mode)',
        () async {
      await service.load();
      service.syncCallback = null;

      await service.setVolumeMethod(VolumeMethod.referenceTable);

      expect(service.current.volumeMethod, VolumeMethod.referenceTable);
    });
  });
}
