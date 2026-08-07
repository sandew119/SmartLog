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

    // Now go through the real app code -- this must run the v1->v4 upgrade.
    final stackRow = await LocalDB.getStack(legacyStackId);

    expect(stackRow, isNotNull);
    expect(stackRow!["name"], "Legacy Stack");
    expect((stackRow["totalVolume"] as num).toDouble(), 12.5);
    // New columns exist with sane defaults for pre-existing rows.
    expect((stackRow["totalCost"] as num).toDouble(), 0);

    // v4 stack detail columns exist and are null on pre-existing rows.
    expect(stackRow.containsKey("customerName"), isTrue);
    expect(stackRow["customerName"], isNull);
    expect(stackRow["remarks"], isNull);

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

  test('a stack round-trips its customer name and remarks', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_stack_details_${DateTime.now().microsecondsSinceEpoch}.db",
    );

    final stackId = await LocalDB.createStack(
      "Lorry 4",
      0,
      customerName: "  Perera Timbers  ",
      remarks: "Collect Friday",
    );

    final row = await LocalDB.getStack(stackId);

    // Stored trimmed, so a stray space can't create a second "customer".
    expect(row!["customerName"], "Perera Timbers");
    expect(row["remarks"], "Collect Friday");
  });

  test('a blank customer name or remark is stored as null, not ""', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_stack_blank_${DateTime.now().microsecondsSinceEpoch}.db",
    );

    final stackId = await LocalDB.createStack(
      "Unnamed buyer",
      0,
      customerName: "   ",
      remarks: "",
    );

    final row = await LocalDB.getStack(stackId);

    // One check downstream ("is it null?") rather than two.
    expect(row!["customerName"], isNull);
    expect(row["remarks"], isNull);
  });

  test('stack details can be edited after the stack is created', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_stack_edit_${DateTime.now().microsecondsSinceEpoch}.db",
    );

    final stackId = await LocalDB.createStack("Lorry 5", 0);

    await LocalDB.updateStackDetails(
      stackId,
      customerName: "Silva & Sons",
      remarks: "Half paid",
    );

    final row = await LocalDB.getStack(stackId);

    expect(row!["customerName"], "Silva & Sons");
    expect(row["remarks"], "Half paid");
    expect(row["name"], "Lorry 5");
  });
}
