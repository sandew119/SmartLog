import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartlog2/database/local_db.dart';

void main() {
  test(
      'opening a legacy v1 database upgrades it to v2 without losing '
      'existing data', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final path = join(
      Directory.systemTemp.path,
      "smartlog_migration_test_${DateTime.now().microsecondsSinceEpoch}.db",
    );

    LocalDB.testDatabasePath = path;

    if (await databaseExists(path)) {
      await deleteDatabase(path);
    }

    // Simulate a pre-existing v1 install (the original schema, before
    // createdAt/totalCost/cost columns existed).
    final legacyDb = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE stacks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            totalVolume REAL
          )
        ''');

        await db.execute('''
          CREATE TABLE logs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            stackId INTEGER,
            diameter REAL,
            lengthFeet REAL,
            volume REAL
          )
        ''');
      },
    );

    final legacyStackId = await legacyDb.insert(
      "stacks",
      {"name": "Legacy Stack", "totalVolume": 12.5},
    );

    await legacyDb.insert(
      "logs",
      {
        "stackId": legacyStackId,
        "diameter": 10.0,
        "lengthFeet": 8.0,
        "volume": 12.5,
      },
    );

    await legacyDb.close();

    // Now go through the real app code -- this must run the v1->v3 upgrade.
    final stackRow = await LocalDB.getStack(legacyStackId);

    expect(stackRow, isNotNull);
    expect(stackRow!["name"], "Legacy Stack");
    expect((stackRow["totalVolume"] as num).toDouble(), 12.5);
    // New columns exist with sane defaults for pre-existing rows.
    expect((stackRow["totalCost"] as num).toDouble(), 0);

    final logs = await LocalDB.getLogsForStack(legacyStackId);
    expect(logs.length, 1);
    expect((logs.first["cost"] as num).toDouble(), 0);

    // v3 provenance columns exist and are null on pre-existing rows rather
    // than blocking the upgrade.
    expect(logs.first.containsKey("measurementSource"), isTrue);
    expect(logs.first["measurementSource"], isNull);
    expect(logs.first["rawDiameterInches"], isNull);
    expect(logs.first["deductionInches"], isNull);
    expect(logs.first["diameterToleranceInches"], isNull);
    expect(logs.first["measurementQuality"], isNull);
    expect(logs.first["diameterProfile"], isNull);

    // New functionality works against the upgraded schema.
    await LocalDB.addLogAndUpdateStackVolume(
      stackId: legacyStackId,
      diameter: 9,
      lengthFeet: 6,
      volume: 5.0,
      cost: 30,
    );

    final updatedStack = await LocalDB.getStack(legacyStackId);
    expect((updatedStack!["totalCost"] as num).toDouble(), 30);
  });

  test('a v3 log round-trips its measurement provenance', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_provenance_test_${DateTime.now().microsecondsSinceEpoch}.db",
    );

    final logId = await LocalDB.addStandaloneLog(
      diameter: 12.0,
      lengthFeet: 8.0,
      volume: 6.28,
      measurementSource: "lidar",
      rawDiameterInches: 14.0,
      deductionInches: 2.0,
      diameterToleranceInches: 0.3,
      measurementQuality: "good",
      diameterProfile: "[14.8,14.2,14.0,14.5]",
    );

    final row = await LocalDB.getLog(logId);

    expect(row, isNotNull);
    // The stored diameter is post-deduction; the raw measurement and the
    // allowance are both retained so a disputed figure can be reconstructed.
    expect((row!["diameter"] as num).toDouble(), 12.0);
    expect((row["rawDiameterInches"] as num).toDouble(), 14.0);
    expect((row["deductionInches"] as num).toDouble(), 2.0);
    expect(row["measurementSource"], "lidar");
    expect((row["diameterToleranceInches"] as num).toDouble(), 0.3);
    expect(row["measurementQuality"], "good");
    expect(row["diameterProfile"], "[14.8,14.2,14.0,14.5]");
  });
}
