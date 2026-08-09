import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/screens/developer_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/async_pump.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  var counter = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    await LocalDB.resetForTesting();
    LocalDB.testDatabasePath =
        "file:dev_screen_${counter++}?mode=memory&cache=shared";
  });

  tearDown(() async {
    await LocalDB.resetForTesting();
  });

  group('reading the database on the device', () {
    test('reports the migration version that actually ran', () async {
      // Read from SQLite itself, not from the constant in the code: the
      // interesting question is whether the migration reached this phone.
      expect(await LocalDB.currentSchemaVersion(), LocalDB.schemaVersion);
    });

    test('lists every real table with its row count', () async {
      await LocalDB.createStack("Demo", 0);

      final tables = await LocalDB.tableSummaries();
      final names = tables.map((t) => t.name).toList();

      expect(names, containsAll(["stacks", "logs", "sync_outbox"]));

      // SQLite's own bookkeeping tables would be noise on screen.
      expect(names.any((n) => n.startsWith("sqlite_")), isFalse);
      expect(names, isNot(contains("android_metadata")));

      final stacks = tables.firstWhere((t) => t.name == "stacks");
      expect(stacks.rows, 1);

      // The columns come from the file, so a schema change cannot leave this
      // screen quietly describing a database that no longer exists.
      expect(
        stacks.columns.any((c) => c.startsWith("cloudId")),
        isTrue,
      );
    });

    test('counts rows per table rather than in total', () async {
      final stackId = await LocalDB.createStack("Counting", 0);

      for (var i = 0; i < 3; i++) {
        await LocalDB.addLogAndUpdateStackVolume(
          stackId: stackId,
          diameter: 20,
          lengthFeet: 10,
          volume: 5,
        );
      }

      final tables = await LocalDB.tableSummaries();

      expect(tables.firstWhere((t) => t.name == "stacks").rows, 1);
      expect(tables.firstWhere((t) => t.name == "logs").rows, 3);
    });
  });

  group('the screen itself', () {
    testWidgets('shows the schema version and the tables', (tester) async {
      await tester.runAsync(() async {
        await LocalDB.createStack("Teak load", 0);

        await tester.pumpWidget(
          const MaterialApp(home: DeveloperScreen()),
        );

        await pumpUntilFound(
            tester, find.text("schema v${LocalDB.schemaVersion}"));

        // The table list is collapsed so the cards below stay reachable;
        // opening it is what a demonstration would actually do.
        await tester.tap(find.textContaining("tables,"));
        await tester.pumpAndSettle();

        expect(find.text("stacks"), findsOneWidget);
        expect(find.text("logs"), findsOneWidget);
        expect(find.text("sync_outbox"), findsOneWidget);
        expect(find.text("1 row"), findsWidgets);
      });
    });

    testWidgets('an empty queue says everything is backed up', (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: DeveloperScreen()),
        );

        // Wait for the thing being asserted, not for a sibling of it: the
        // screen reloads every two seconds, so anything checked after a
        // separate wait is checked against a possibly newer frame.
        await pumpUntilFound(tester, find.text("Nothing waiting."));
        expect(find.text("empty"), findsOneWidget);
      });
    });

    testWidgets('queued work appears, and the failure reason with it',
        (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: DeveloperScreen()),
        );
        await pumpUntilFound(tester, find.text("Nothing waiting."));

        // Exactly what saving a log offline leaves behind.
        await LocalDB.enqueueUpsert(entity: "stack", localId: 7);

        // The screen polls, so this must appear without any interaction --
        // which is the whole point during a live demonstration.
        await pumpUntilFound(tester, find.text("1 waiting"));
        expect(find.text("upsert stack #7"), findsOneWidget);

        final queued = await LocalDB.pendingSyncItems();
        await LocalDB.recordSyncAttempt(
          queued.first["id"] as int,
          "[cloud_firestore/permission-denied] Missing permissions",
        );

        await pumpUntilFound(tester, find.text("1 attempt"));
        expect(
          find.textContaining("permission-denied"),
          findsOneWidget,
        );
      });
    });

    testWidgets('shows settings, which do not live in SQLite at all',
        (tester) async {
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({
          "volume_method": "referenceTable",
          "girth_deduction_inches": 2.5,
          "device_sync_id": "abc123",
        });

        // setMockInitialValues replaces the stored values but not the
        // instance the plugin already cached in this isolate, so without a
        // reload the screen keeps reading the previous test's snapshot.
        await (await SharedPreferences.getInstance()).reload();

        await tester.pumpWidget(
          const MaterialApp(home: DeveloperScreen()),
        );

        await pumpUntilFound(tester, find.text("3 keys"));

        expect(find.text("volume_method"), findsOneWidget);
        expect(find.text("referenceTable"), findsOneWidget);
        expect(find.text("device_sync_id"), findsOneWidget);

        // Two of these mirror to the cloud and one is device-local, and the
        // screen has to be able to say which is which -- otherwise the claim
        // that settings sync is unverifiable.
        expect(find.byIcon(Icons.cloud_done), findsNWidgets(2));
        expect(find.byIcon(Icons.phone_android), findsOneWidget);
      });
    });

    testWidgets('reads whatever keys exist rather than a fixed list',
        (tester) async {
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({
          "saw_mode": "fixedThickness",
          "some_future_setting": true,
        });
        await (await SharedPreferences.getInstance()).reload();

        await tester.pumpWidget(
          const MaterialApp(home: DeveloperScreen()),
        );

        await pumpUntilFound(tester, find.text("2 keys"));

        // A hardcoded list would go stale the first time anyone adds a
        // setting, and the screen would quietly under-report.
        expect(find.text("some_future_setting"), findsOneWidget);
      });
    });

    testWidgets('stops polling when it is closed', (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: DeveloperScreen()),
        );
        await pumpUntilFound(tester, find.text("Nothing waiting."));

        // A 2-second timer left running against a closed database is how a
        // debug screen turns into a crash on the way out of it.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(seconds: 5));

        expect(tester.takeException(), isNull);
      });
    });
  });
}
