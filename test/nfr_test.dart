import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/services/session_timeout_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The non-functional requirements that can actually be proved on a machine
/// with no device and no users.
///
/// Usability (SUS), model accuracy (F1) and measurement reliability all need
/// people, a trained model, or real logs. Data storage does not — so it is
/// measured here rather than asserted in a document.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  var counter = 0;

  setUp(() async {
    await LocalDB.resetForTesting();
    LocalDB.testDatabasePath = "file:nfr_${counter++}?mode=memory&cache=shared";
  });

  tearDown(() async {
    SessionTimeoutService.instance.resetForTesting();
    await LocalDB.resetForTesting();
  });

  group('NFR: data storage — under 2 seconds at 500 entries', () {
    test('the saved-records query stays fast with a full database', () async {
      // The requirement names 500 entries, so that is what is measured --
      // not 10, which any implementation passes.
      const entries = 500;

      for (var i = 0; i < entries; i++) {
        final stackId = await LocalDB.createStack(
          "Stack $i",
          0,
          customerName: "Customer ${i % 40}",
        );

        await LocalDB.addLogAndUpdateStackVolume(
          stackId: stackId,
          diameter: 20 + (i % 15),
          lengthFeet: 10,
          volume: 5,
        );
      }

      final watch = Stopwatch()..start();
      final stacks = await LocalDB.getStacks();
      watch.stop();

      expect(stacks, hasLength(entries));
      expect(
        watch.elapsedMilliseconds,
        lessThan(2000),
        reason: "retrieval of $entries stacks took "
            "${watch.elapsedMilliseconds}ms",
      );
    });

    test('search stays fast too, because it filters in SQL', () async {
      for (var i = 0; i < 500; i++) {
        await LocalDB.createStack(
          "Stack $i",
          0,
          customerName: i == 250 ? "Wijesinghe" : "Customer ${i % 40}",
        );
      }

      final watch = Stopwatch()..start();
      final found = await LocalDB.searchStacks(keyword: "Wijesinghe");
      watch.stop();

      expect(found, hasLength(1));

      // Pulling all 500 rows into Dart and filtering there would get slower
      // exactly as the user builds up history. The database does it instead.
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('a session left open on a bench does not stay open', () {
    test('the countdown starts on sign-in and fires', () async {
      final service = SessionTimeoutService.instance;

      var signedOut = false;

      service.timeout = const Duration(milliseconds: 60);
      service.onTimeout = () async => signedOut = true;

      service.start();
      expect(service.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(signedOut, isTrue);
    });

    test('any interaction defers it', () async {
      final service = SessionTimeoutService.instance;

      var signedOut = false;
      service.timeout = const Duration(milliseconds: 120);
      service.onTimeout = () async => signedOut = true;

      service.start();

      // Someone measuring a stack touches the screen between logs. They must
      // not be logged out mid-count.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        service.recordActivity();
      }

      expect(signedOut, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(signedOut, isTrue);
    });

    test('signing out stops the timer rather than leaving it armed', () async {
      final service = SessionTimeoutService.instance;

      var fired = false;
      service.timeout = const Duration(milliseconds: 60);
      service.onTimeout = () async => fired = true;

      service.start();
      service.stop();

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(fired, isFalse);
      expect(service.isRunning, isFalse);
    });

    test('activity before sign-in does nothing', () {
      final service = SessionTimeoutService.instance;

      // Guest mode has no session to expire.
      service.recordActivity();
      expect(service.isRunning, isFalse);
    });

    test('the default is generous enough for real work', () {
      // Half an hour. A mill worker may not touch the screen for several
      // minutes between logs, and an app that signs them out mid-count gets
      // uninstalled rather than tolerated.
      expect(SessionTimeoutService.defaultTimeout.inMinutes, 30);
    });
  });
}
