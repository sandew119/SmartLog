import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartlog2/database/local_db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // Each test file needs its own database file -- flutter test runs
    // files concurrently, and they'd otherwise all collide on the same
    // real on-device path.
    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_local_db_test_${DateTime.now().microsecondsSinceEpoch}.db",
    );
  });

  test('createStack + addLogAndUpdateStackVolume accumulates volume and cost',
      () async {
    final name = "Test Stack ${DateTime.now().microsecondsSinceEpoch}";

    final stackId = await LocalDB.createStack(name, 0);

    final firstLogId = await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: 12,
      lengthFeet: 8,
      volume: 6.28,
      cost: 100,
    );

    await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: 10,
      lengthFeet: 6,
      volume: 3.27,
      cost: 50,
    );

    expect(firstLogId, isPositive);

    final stackRow = await LocalDB.getStack(stackId);
    expect(stackRow, isNotNull);
    expect((stackRow!["totalVolume"] as num).toDouble(), closeTo(9.55, 0.01));
    expect((stackRow["totalCost"] as num).toDouble(), 150);
    expect(stackRow["createdAt"], isNotNull);

    final logs = await LocalDB.getLogsForStack(stackId);
    expect(logs.length, 2);
  });

  test('addStandaloneLog is retrievable via getStandaloneLogs and getLog',
      () async {
    final id = await LocalDB.addStandaloneLog(
      diameter: 8,
      lengthFeet: 4,
      volume: 1.4,
      cost: 20,
    );

    final row = await LocalDB.getLog(id);
    expect(row, isNotNull);
    expect(row!["stackId"], isNull);

    final standalone = await LocalDB.getStandaloneLogs();
    expect(standalone.any((r) => r["id"] == id), isTrue);
  });

  test('deleteLog decrements its parent stack totals', () async {
    final name = "Decrement Test ${DateTime.now().microsecondsSinceEpoch}";
    final stackId = await LocalDB.createStack(name, 0);

    final logId = await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: 12,
      lengthFeet: 8,
      volume: 5.0,
      cost: 100,
    );

    await LocalDB.deleteLog(logId);

    final stackRow = await LocalDB.getStack(stackId);
    expect((stackRow!["totalVolume"] as num).toDouble(), closeTo(0, 0.0001));
    expect((stackRow["totalCost"] as num).toDouble(), 0);

    final remainingLogs = await LocalDB.getLogsForStack(stackId);
    expect(remainingLogs, isEmpty);
  });

  test('deleteStack cascades to delete every log inside it', () async {
    final name = "Cascade Test ${DateTime.now().microsecondsSinceEpoch}";
    final stackId = await LocalDB.createStack(name, 0);

    await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: 12,
      lengthFeet: 8,
      volume: 5.0,
    );

    await LocalDB.deleteStack(stackId);

    final stackRow = await LocalDB.getStack(stackId);
    expect(stackRow, isNull);

    final logs = await LocalDB.getLogsForStack(stackId);
    expect(logs, isEmpty);
  });

  test('deleting a standalone log does not touch any stack', () async {
    final id = await LocalDB.addStandaloneLog(
      diameter: 9,
      lengthFeet: 5,
      volume: 2.0,
      cost: 40,
    );

    await LocalDB.deleteLog(id);

    final row = await LocalDB.getLog(id);
    expect(row, isNull);
  });
}
