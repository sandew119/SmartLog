import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDB {
  static Database? _database;

  /// Overrides the database file path -- only ever set by tests, so each
  /// test file can use its own isolated database instead of all colliding
  /// on the same real on-device path.
  static String? testDatabasePath;

  static Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = testDatabasePath ??
        join(
          await getDatabasesPath(),
          "smartlog.db",
        );

    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE stacks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            totalVolume REAL,
            totalCost REAL DEFAULT 0,
            createdAt TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE logs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            stackId INTEGER,
            diameter REAL,
            lengthFeet REAL,
            volume REAL,
            cost REAL DEFAULT 0,
            createdAt TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE stacks ADD COLUMN totalCost REAL DEFAULT 0",
          );
          await db.execute(
            "ALTER TABLE stacks ADD COLUMN createdAt TEXT",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN cost REAL DEFAULT 0",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN createdAt TEXT",
          );
        }
      },
    );
  }

  static Future<int> createStack(
    String name,
    double totalVolume, {
    double totalCost = 0,
  }) async {
    final db = await database;

    return await db.insert(
      "stacks",
      {
        "name": name,
        "totalVolume": totalVolume,
        "totalCost": totalCost,
        "createdAt": DateTime.now().toIso8601String(),
      },
    );
  }

  static Future<void> addLog({
    required int stackId,
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
  }) async {
    final db = await database;

    await db.insert(
      "logs",
      {
        "stackId": stackId,
        "diameter": diameter,
        "lengthFeet": lengthFeet,
        "volume": volume,
        "cost": cost,
        "createdAt": DateTime.now().toIso8601String(),
      },
    );
  }

  /// Saves a log that doesn't belong to any stack.
  static Future<int> addStandaloneLog({
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
  }) async {
    final db = await database;

    return await db.insert(
      "logs",
      {
        "stackId": null,
        "diameter": diameter,
        "lengthFeet": lengthFeet,
        "volume": volume,
        "cost": cost,
        "createdAt": DateTime.now().toIso8601String(),
      },
    );
  }

  static Future<List<Map<String, dynamic>>> getStacks() async {
    final db = await database;

    return await db.query(
      "stacks",
      orderBy: "id DESC",
    );
  }

  static Future<Map<String, dynamic>?> getStack(int id) async {
    final db = await database;

    final rows = await db.query(
      "stacks",
      where: "id = ?",
      whereArgs: [id],
    );

    return rows.isEmpty ? null : rows.first;
  }

  /// Logs with no parent stack (saved as one-off entries).
  static Future<List<Map<String, dynamic>>> getStandaloneLogs() async {
    final db = await database;

    return await db.query(
      "logs",
      where: "stackId IS NULL",
      orderBy: "id DESC",
    );
  }

  static Future<Map<String, dynamic>?> getLog(int id) async {
    final db = await database;

    final rows = await db.query(
      "logs",
      where: "id = ?",
      whereArgs: [id],
    );

    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, dynamic>>> getLogsForStack(
    int stackId,
  ) async {
    final db = await database;

    return await db.query(
      "logs",
      where: "stackId = ?",
      whereArgs: [stackId],
      orderBy: "id DESC",
    );
  }

  /// Inserts a log under [stackId] and adds [volume]/[cost] onto that
  /// stack's running totals, in a single transaction. Returns the new log's
  /// id.
  static Future<int> addLogAndUpdateStackVolume({
    required int stackId,
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
  }) async {
    final db = await database;

    return await db.transaction((txn) async {
      final logId = await txn.insert(
        "logs",
        {
          "stackId": stackId,
          "diameter": diameter,
          "lengthFeet": lengthFeet,
          "volume": volume,
          "cost": cost,
          "createdAt": DateTime.now().toIso8601String(),
        },
      );

      await txn.rawUpdate(
        "UPDATE stacks SET totalVolume = totalVolume + ?, totalCost = totalCost + ? WHERE id = ?",
        [volume, cost, stackId],
      );

      return logId;
    });
  }

  /// Deletes a stack and every log inside it.
  static Future<void> deleteStack(int id) async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.delete("logs", where: "stackId = ?", whereArgs: [id]);
      await txn.delete("stacks", where: "id = ?", whereArgs: [id]);
    });
  }

  /// Deletes a single log, decrementing its parent stack's running totals
  /// first if it belongs to one.
  static Future<void> deleteLog(int id) async {
    final db = await database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        "logs",
        where: "id = ?",
        whereArgs: [id],
      );

      if (rows.isEmpty) return;

      final log = rows.first;
      final stackId = log["stackId"] as int?;

      if (stackId != null) {
        final volume = (log["volume"] as num?)?.toDouble() ?? 0;
        final cost = (log["cost"] as num?)?.toDouble() ?? 0;

        await txn.rawUpdate(
          "UPDATE stacks SET totalVolume = totalVolume - ?, totalCost = totalCost - ? WHERE id = ?",
          [volume, cost, stackId],
        );
      }

      await txn.delete("logs", where: "id = ?", whereArgs: [id]);
    });
  }
}
