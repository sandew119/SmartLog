import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class LocalDB {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = join(
      await getDatabasesPath(),
      "smartlog.db",
    );

    return openDatabase(
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
  }

  static Future<int> createStack(
    String name,
    double totalVolume,
  ) async {
    final db = await database;

    return await db.insert(
      "stacks",
      {
        "name": name,
        "totalVolume": totalVolume,
      },
    );
  }

  static Future<void> addLog({
    required int stackId,
    required double diameter,
    required double lengthFeet,
    required double volume,
  }) async {
    final db = await database;

    await db.insert(
      "logs",
      {
        "stackId": stackId,
        "diameter": diameter,
        "lengthFeet": lengthFeet,
        "volume": volume,
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

  /// Inserts a log under [stackId] and adds [volume] onto that stack's
  /// running total, in a single transaction.
  static Future<void> addLogAndUpdateStackVolume({
    required int stackId,
    required double diameter,
    required double lengthFeet,
    required double volume,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.insert(
        "logs",
        {
          "stackId": stackId,
          "diameter": diameter,
          "lengthFeet": lengthFeet,
          "volume": volume,
        },
      );

      await txn.rawUpdate(
        "UPDATE stacks SET totalVolume = totalVolume + ? WHERE id = ?",
        [volume, stackId],
      );
    });
  }
}
