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

    // Now go through the real app code -- this must run the v1->v2 upgrade.
    final stackRow = await LocalDB.getStack(legacyStackId);

    expect(stackRow, isNotNull);
    expect(stackRow!["name"], "Legacy Stack");
    expect((stackRow["totalVolume"] as num).toDouble(), 12.5);
    // New columns exist with sane defaults for pre-existing rows.
    expect((stackRow["totalCost"] as num).toDouble(), 0);

    final logs = await LocalDB.getLogsForStack(legacyStackId);
    expect(logs.length, 1);
    expect((logs.first["cost"] as num).toDouble(), 0);

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
}
