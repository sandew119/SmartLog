import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/repositories/stack_repository.dart';
import 'package:smartlog2/services/cloud_restore_service.dart';
import 'package:smartlog2/services/cloud_sync_engine.dart';
import 'package:smartlog2/services/cloud_sync_status.dart';
import 'package:smartlog2/services/cloud_transport.dart';
import 'package:smartlog2/services/user_preferences_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A cloud that keeps everything in memory and can be told to break.
class FakeCloud implements CloudTransport {
  final Map<String, Map<String, Object?>> stacks = {};
  final Map<String, Map<String, Map<String, Object?>>> logs = {};
  final Map<String, Map<String, Object?>> standalone = {};
  Map<String, Object?> settings = {};

  /// When set, every call throws it. Stands in for no signal, or for rules
  /// that reject the write.
  Object? failure;

  int writes = 0;

  void _check() {
    if (failure != null) throw failure!;
  }

  @override
  Future<void> upsertStack(
      String uid, String id, Map<String, Object?> d) async {
    _check();
    writes++;
    stacks[id] = d;
  }

  @override
  Future<void> upsertLog(
    String uid,
    String stackId,
    String id,
    Map<String, Object?> d,
  ) async {
    _check();
    writes++;
    (logs[stackId] ??= {})[id] = d;
  }

  @override
  Future<void> upsertStandaloneLog(
    String uid,
    String id,
    Map<String, Object?> d,
  ) async {
    _check();
    writes++;
    standalone[id] = d;
  }

  @override
  Future<void> upsertSettings(String uid, Map<String, Object?> d) async {
    _check();
    writes++;
    settings = {...settings, ...d};
  }

  @override
  Future<void> deleteStack(String uid, String id) async {
    _check();
    stacks.remove(id);
    logs.remove(id);
  }

  @override
  Future<void> deleteLog(String uid, String? stackId, String id) async {
    _check();
    if (stackId == null) {
      standalone.remove(id);
    } else {
      logs[stackId]?.remove(id);
    }
  }

  @override
  Future<CloudSnapshot> downloadAll(String uid) async {
    _check();

    return CloudSnapshot(
      stacks: [
        for (final entry in stacks.entries)
          {...entry.value, "cloudId": entry.key},
      ],
      logsByStack: {
        for (final stack in logs.entries)
          stack.key: [
            for (final log in stack.value.entries)
              {...log.value, "cloudId": log.key},
          ],
      },
      standaloneLogs: [
        for (final entry in standalone.entries)
          {...entry.value, "cloudId": entry.key},
      ],
      settings: settings.isEmpty ? null : settings,
    );
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late FakeCloud cloud;
  late CloudSyncEngine engine;
  var counter = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CloudSyncStatus.instance.resetForTesting();
    UserPreferencesService.instance.resetForTesting();

    await LocalDB.resetForTesting();

    // A distinct in-memory database per test, so one test's stacks can never
    // be counted by the next.
    LocalDB.testDatabasePath =
        "file:sync_test_${counter++}?mode=memory&cache=shared";

    cloud = FakeCloud();
    engine = CloudSyncEngine(transport: cloud, uid: () => "user-1");
  });

  tearDown(() async {
    engine.disposeForTesting();
    await LocalDB.resetForTesting();
  });

  group('the outbox never loses work', () {
    test('a queued stack reaches the cloud', () async {
      final id = await LocalDB.createStack("Teak load", 0);

      await engine.queueStack(id);
      await engine.drain();

      expect(cloud.stacks, hasLength(1));
      expect(cloud.stacks.values.single["name"], "Teak load");
      expect(await LocalDB.pendingSyncCount(), 0);
    });

    test('work survives the cloud being unreachable, and goes later', () async {
      final id = await LocalDB.createStack("Mahogany", 0);

      cloud.failure = Exception("no signal");

      await engine.queueStack(id);
      await engine.drain();

      // The old design pushed with unawaited() and no record: this stack
      // would simply never have existed in the cloud, and nobody would know.
      expect(cloud.stacks, isEmpty);
      expect(await LocalDB.pendingSyncCount(), 1);

      cloud.failure = null;
      await engine.drain();

      expect(cloud.stacks, hasLength(1));
      expect(await LocalDB.pendingSyncCount(), 0);
    });

    test('a failure is reported rather than swallowed', () async {
      final id = await LocalDB.createStack("Pine", 0);

      cloud.failure = Exception("denied");
      await engine.queueStack(id);
      await engine.drain();

      expect(CloudSyncStatus.instance.current.state, CloudSyncState.failed);
    });

    test('twenty edits to one stack are one upload, not twenty', () async {
      final id = await LocalDB.createStack("Edited often", 0);

      for (var i = 0; i < 20; i++) {
        await LocalDB.enqueueUpsert(entity: SyncEntity.stack, localId: id);
      }

      expect(await LocalDB.pendingSyncCount(), 1);

      await engine.drain();
      expect(cloud.writes, 1);
    });

    test('the queue stops at a failure instead of running past it', () async {
      // A log cannot be written under a stack that is not there yet, so
      // skipping ahead would scatter orphans through the cloud.
      final stackId = await LocalDB.createStack("Parent", 0);
      final logId = await LocalDB.addLogAndUpdateStackVolume(
        stackId: stackId,
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );

      await engine.queueStack(stackId);
      await engine.queueLog(logId, stackId: stackId);

      cloud.failure = Exception("down");
      await engine.drain();

      expect(await LocalDB.pendingSyncCount(), 2);
    });
  });

  group('backfilling data written while syncing was broken', () {
    test('queueEverything sweeps up stacks, logs and settings', () async {
      // Written straight to the database, exactly as the app did during the
      // whole period the security rules were rejecting every upload.
      final stackId = await LocalDB.createStack("Old stack", 0);
      await LocalDB.addLogAndUpdateStackVolume(
        stackId: stackId,
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );
      await LocalDB.addStandaloneLog(diameter: 15, lengthFeet: 8, volume: 2);
      await LocalDB.clearOutbox();

      expect(await LocalDB.pendingSyncCount(), 0);

      await engine.queueEverything();
      await engine.drain();

      expect(cloud.stacks, hasLength(1));
      expect(cloud.logs.values.single, hasLength(1));
      expect(cloud.standalone, hasLength(1));
      expect(cloud.settings, isNotEmpty);
    });
  });

  group('what actually gets stored', () {
    test('the measurement audit trail goes up with the log', () async {
      final logId = await LocalDB.addStandaloneLog(
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
        measurementSource: "lidar",
        rawDiameterInches: 21.5,
        deductionInches: 1.5,
        measurementQuality: "good",
      );

      await engine.queueLog(logId);
      await engine.drain();

      final stored = cloud.standalone.values.single;

      // LogModel.toMap() drops all of these. Uploading that instead of the
      // row would have thrown away the provenance a disputed volume is
      // settled with.
      expect(stored["measurementSource"], "lidar");
      expect(stored["rawDiameterInches"], 21.5);
      expect(stored["deductionInches"], 1.5);
      expect(stored["measurementQuality"], "good");
    });
  });

  group('restoring onto a new phone', () {
    test('brings back stacks, their logs, standalone logs and settings',
        () async {
      final stackId = await LocalDB.createStack("Customer A", 0);
      await LocalDB.addLogAndUpdateStackVolume(
        stackId: stackId,
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );
      await LocalDB.addStandaloneLog(diameter: 15, lengthFeet: 8, volume: 2);

      await engine.queueEverything();
      await engine.drain();

      // A brand new phone: same account, empty database.
      await LocalDB.resetForTesting();
      LocalDB.testDatabasePath =
          "file:sync_restore_${counter++}?mode=memory&cache=shared";

      expect(await LocalDB.isEmpty(), isTrue);

      final restore = CloudRestoreService(
        transport: cloud,
        uid: () => "user-1",
      );

      final outcome = await restore.restoreIfLocalIsEmpty();

      expect(outcome.stacks, 1);
      expect(outcome.logs, 2);

      final stacks = await LocalDB.getStacks();
      expect(stacks.single["name"], "Customer A");

      // The log has to land under the stack's *new* local id. Getting this
      // wrong reparents someone's timber into the wrong customer's stack.
      final restoredLogs = await LocalDB.getLogsForStack(
        stacks.single["id"] as int,
      );
      expect(restoredLogs, hasLength(1));
      expect(await LocalDB.getStandaloneLogs(), hasLength(1));
    });

    test('re-uploading restored data updates it instead of duplicating it',
        () async {
      final stackId = await LocalDB.createStack("Only once", 0);
      await engine.queueEverything();
      await engine.drain();

      expect(cloud.stacks, hasLength(1));
      final originalId = cloud.stacks.keys.single;

      await LocalDB.resetForTesting();
      LocalDB.testDatabasePath =
          "file:sync_dupe_${counter++}?mode=memory&cache=shared";

      await CloudRestoreService(transport: cloud, uid: () => "user-1")
          .restore();

      // The whole reason rows carry a cloudId: without it the restored row
      // would get a fresh local id, mint a second document, and the backup
      // would grow a duplicate with every reinstall.
      await engine.queueEverything();
      await engine.drain();

      expect(cloud.stacks, hasLength(1));
      expect(cloud.stacks.keys.single, originalId);
      expect(stackId, isNotNull);
    });

    test('refuses to restore over a database that already has work in it',
        () async {
      await LocalDB.createStack("Cloud copy", 0);
      await engine.queueEverything();
      await engine.drain();

      // Same phone, still holding its own data.
      final outcome =
          await CloudRestoreService(transport: cloud, uid: () => "user-1")
              .restoreIfLocalIsEmpty();

      expect(outcome.restoredAnything, isFalse);
      expect(await LocalDB.getStacks(), hasLength(1));
    });
  });

  group('deletions', () {
    test('deleting a stack removes it and its logs from the cloud', () async {
      final stackId = await StackRepository.instance.createStackAndAddLog(
        name: "Doomed",
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );

      await engine.drain();
      expect(cloud.stacks, hasLength(1));

      await StackRepository.instance.deleteStack(stackId);
      await engine.drain();

      expect(cloud.stacks, isEmpty);
      expect(cloud.logs, isEmpty);
      expect(await LocalDB.pendingSyncCount(), 0);
    });

    test('a row created and deleted offline is never uploaded at all',
        () async {
      cloud.failure = Exception("offline");

      final stackId = await StackRepository.instance.createStackAndAddLog(
        name: "Mistake",
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );
      await engine.drain();

      await StackRepository.instance.deleteStack(stackId);

      cloud.failure = null;
      await engine.drain();

      // It never reached the cloud, so there is nothing to create and
      // nothing to delete -- the queue should simply be empty.
      expect(cloud.stacks, isEmpty);
      expect(await LocalDB.pendingSyncCount(), 0);
    });
  });
}
