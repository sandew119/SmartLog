import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// One table as it exists on the device right now.
class TableSummary {
  final String name;
  final int rows;
  final List<String> columns;

  const TableSummary({
    required this.name,
    required this.rows,
    required this.columns,
  });
}

class LocalDB {
  /// The migration version this build of the code expects.
  ///
  /// Named rather than repeated, so the version passed to [openDatabase] and
  /// the version anything else checks against cannot drift apart -- which is
  /// precisely the bug a schema-version display exists to catch.
  static const int schemaVersion = 7;

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

  /// Test-only: closes and forgets the cached connection so the next access
  /// reopens using the current [testDatabasePath].
  ///
  /// Without this, setting [testDatabasePath] between tests in the same file
  /// has no effect -- the already-open database is cached statically and
  /// every test silently shares the first one's data.
  static Future<void> resetForTesting() async {
    final db = _database;
    _database = null;

    if (db != null) {
      try {
        await db.close();
      } catch (_) {}
    }
  }

  static Future<Database> _initDatabase() async {
    final path = testDatabasePath ??
        join(
          await getDatabasesPath(),
          "smartlog.db",
        );

    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE stacks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            totalVolume REAL,
            totalCost REAL DEFAULT 0,
            createdAt TEXT,
            customerName TEXT,
            remarks TEXT,
            cloudId TEXT
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
            createdAt TEXT,
            measurementSource TEXT,
            rawDiameterInches REAL,
            deductionInches REAL,
            diameterToleranceInches REAL,
            measurementQuality TEXT,
            diameterProfile TEXT,
            cloudId TEXT
          )
        ''');

        await db.execute(_createOutboxTable);

        for (final statement in _v6Tables) {
          await db.execute(statement);
        }

        for (final statement in _v7Columns) {
          await db.execute(statement);
        }
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

        if (oldVersion < 3) {
          // Measurement provenance. Without it a disputed volume can't be
          // audited -- you can't tell whether a figure came from a sensor
          // or a keyboard, or what allowance was applied at the time.
          await db.execute(
            "ALTER TABLE logs ADD COLUMN measurementSource TEXT",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN rawDiameterInches REAL",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN deductionInches REAL",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN diameterToleranceInches REAL",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN measurementQuality TEXT",
          );
          await db.execute(
            "ALTER TABLE logs ADD COLUMN diameterProfile TEXT",
          );
        }

        if (oldVersion < 4) {
          // Who the stack is for, and anything the user wants to remember
          // about it. Both optional -- a stack is still valid without them.
          //
          // Deliberately no company column: the seller's own company is a
          // property of the user, read from their profile when a report is
          // generated, never re-typed per stack.
          await db.execute(
            "ALTER TABLE stacks ADD COLUMN customerName TEXT",
          );
          await db.execute(
            "ALTER TABLE stacks ADD COLUMN remarks TEXT",
          );
        }

        if (oldVersion < 5) {
          // The identity a row has in the cloud, stored next to the row.
          //
          // Without it, restoring onto a new phone gives every row a fresh
          // local id, and the next upload invents a *second* cloud document
          // for data already up there -- the backup would duplicate itself a
          // little more with every reinstall.
          await db.execute("ALTER TABLE stacks ADD COLUMN cloudId TEXT");
          await db.execute("ALTER TABLE logs ADD COLUMN cloudId TEXT");

          await db.execute(_createOutboxTable);
        }

        if (oldVersion < 6) {
          for (final statement in _v6Tables) {
            await db.execute(statement);
          }
        }

        if (oldVersion < 7) {
          for (final statement in _v7Columns) {
            await db.execute(statement);
          }
        }
      },
    );
  }

  /// The five tables the design promises beyond stacks and logs.
  ///
  /// Each one exists because a functional requirement says a record is
  /// *persisted*, not merely displayed -- and a result that vanishes when the
  /// screen closes cannot be reopened, exported, or produced as evidence in a
  /// dispute, which is the entire point of storing it.
  static const List<String> _v6Tables = [
    // The local profile written at registration. Firebase holds the account;
    // this holds the copy the app can read with no connection, which is what
    // lets the saved-records screen name its owner offline.
    //
    // No password column, by design: credentials live in Firebase and the
    // session token in the platform keystore, never in this file.
    """
    CREATE TABLE users(
      uid TEXT PRIMARY KEY,
      name TEXT,
      email TEXT,
      phone TEXT,
      company TEXT,
      createdAt TEXT
    )
    """,

    // A defect found on one log, whether marked by hand while tracing the
    // face or predicted by the model. `confidence` and `automatic` together
    // record how the finding was arrived at, so a cutting plan that routed
    // boards around a flaw can be justified afterwards.
    """
    CREATE TABLE defects(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      logId INTEGER NOT NULL,
      kind TEXT NOT NULL,
      confidence REAL NOT NULL DEFAULT 1,
      automatic INTEGER NOT NULL DEFAULT 0,
      centreX REAL,
      centreY REAL,
      radius REAL,
      imagePath TEXT,
      overlayPath TEXT,
      createdAt TEXT NOT NULL,
      cloudId TEXT,
      FOREIGN KEY (logId) REFERENCES logs (id) ON DELETE CASCADE
    )
    """,

    // The chosen breakdown for a log. One per log: recalculating replaces
    // the previous answer rather than accumulating rival plans nobody can
    // choose between.
    """
    CREATE TABLE cutting_patterns(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      logId INTEGER NOT NULL UNIQUE,
      strategy TEXT NOT NULL,
      boardWidthMm REAL,
      boardThicknessMm REAL NOT NULL,
      bladeThicknessMm REAL NOT NULL,
      boardCount INTEGER NOT NULL,
      yieldPercent REAL NOT NULL,
      boardVolumeCubicFeet REAL NOT NULL,
      wasteVolumeCubicFeet REAL NOT NULL,
      sawPasses INTEGER NOT NULL,
      pricePerCubicFoot REAL NOT NULL DEFAULT 0,
      createdAt TEXT NOT NULL,
      cloudId TEXT,
      FOREIGN KEY (logId) REFERENCES logs (id) ON DELETE CASCADE
    )
    """,

    // What was exported, when, and where the file went. Kept so a report
    // handed to a buyer can be found again and re-sent without regenerating
    // it from data that may since have changed.
    """
    CREATE TABLE reports(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      stackId INTEGER,
      logId INTEGER,
      format TEXT NOT NULL,
      filePath TEXT NOT NULL,
      totalVolumeCubicFeet REAL NOT NULL DEFAULT 0,
      totalCost REAL NOT NULL DEFAULT 0,
      createdAt TEXT NOT NULL
    )
    """,

    // Errors and timings. Capped at 200 rows by the writer, because a
    // diagnostic store that grows without limit eventually costs more than
    // the problem it was meant to help diagnose.
    """
    CREATE TABLE diagnostics(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      module TEXT NOT NULL,
      code TEXT,
      message TEXT,
      durationMs INTEGER,
      createdAt TEXT NOT NULL
    )
    """,
  ];

  /// Columns the SDS relational schema (section 4.5.3) specifies that the
  /// implementation had drifted away from.
  ///
  /// Added rather than argued with: each one backs a requirement the app
  /// genuinely could not meet without it.
  static const List<String> _v7Columns = [
    // SDS: Log(..., notes). EC04 FR12 is explicit that the user "enters
    // optional notes" before saving, and there was nowhere to put them --
    // only a stack could carry a remark, not the individual log it was
    // about.
    "ALTER TABLE logs ADD COLUMN notes TEXT",

    // SDS: Log(..., diameter_1, diameter_2). Both ends of the log, which is
    // what a taper-aware formula needs. The scan already derives a full
    // sectional profile; these record the two ends explicitly so a reading
    // can be checked against a tape at either end.
    "ALTER TABLE logs ADD COLUMN smallEndDiameter REAL",
    "ALTER TABLE logs ADD COLUMN largeEndDiameter REAL",

    // SDS: Stack(..., user_id FK). EC04 FR21 requires that "a user can
    // retrieve only the records owned by that user" -- which nothing local
    // enforced, so two accounts on one phone saw each other's stacks.
    "ALTER TABLE stacks ADD COLUMN userId TEXT",

    // SDS: Stack(..., rate). The agreed price per cubic foot for the batch,
    // which is not recoverable from a total once logs are added or removed.
    "ALTER TABLE stacks ADD COLUMN rate REAL",

    // SDS: Defect(..., severity ENUM('Low','Medium','High')). Kept as TEXT
    // because SQLite has no ENUM; the allowed values live in the Dart enum
    // that writes it.
    "ALTER TABLE defects ADD COLUMN severity TEXT",
  ];

  /// Work waiting to reach the cloud.
  ///
  /// A queue in the same database as the data it describes, so it survives
  /// the app being killed, the phone running out of battery, and a week with
  /// no signal. The design this replaces pushed to Firestore with
  /// `unawaited(...)` and kept no record: anything that failed was simply
  /// gone, and nobody was told.
  static const String _createOutboxTable = """
    CREATE TABLE sync_outbox(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity TEXT NOT NULL,
      operation TEXT NOT NULL,
      localId INTEGER,
      parentLocalId INTEGER,
      cloudId TEXT,
      parentCloudId TEXT,
      queuedAt TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      lastError TEXT
    )
  """;

  /// Queues an upsert, replacing any upsert already queued for the same row.
  ///
  /// Deduplicating matters because an upsert carries no payload -- the row is
  /// re-read when it is finally sent, so it always goes up in its latest
  /// state. Twenty edits to one stack are therefore one upload rather than
  /// twenty, and a backlog cannot grow without bound while the user works
  /// offline for a fortnight.
  static Future<void> enqueueUpsert({
    required String entity,
    required int localId,
    int? parentLocalId,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.delete(
        "sync_outbox",
        where: "entity = ? AND operation = 'upsert' AND localId = ?",
        whereArgs: [entity, localId],
      );

      await txn.insert("sync_outbox", {
        "entity": entity,
        "operation": "upsert",
        "localId": localId,
        "parentLocalId": parentLocalId,
        "queuedAt": DateTime.now().toIso8601String(),
      });
    });
  }

  /// Queues a delete.
  ///
  /// Takes the cloud id rather than the local one because by the time this is
  /// sent the local row is already gone -- there would be nothing left to
  /// look the id up from.
  static Future<void> enqueueDelete({
    required String entity,
    required String cloudId,
    String? parentCloudId,
    int? localId,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      // A row created and deleted before either reached the cloud never
      // needs mentioning at all.
      if (localId != null) {
        await txn.delete(
          "sync_outbox",
          where: "entity = ? AND operation = 'upsert' AND localId = ?",
          whereArgs: [entity, localId],
        );
      }

      await txn.insert("sync_outbox", {
        "entity": entity,
        "operation": "delete",
        "cloudId": cloudId,
        "parentCloudId": parentCloudId,
        "queuedAt": DateTime.now().toIso8601String(),
      });
    });
  }

  /// Queues the one-per-user settings document. Only ever one entry.
  static Future<void> enqueueSettings() async {
    final db = await database;

    await db.transaction((txn) async {
      await txn.delete("sync_outbox", where: "entity = 'settings'");

      await txn.insert("sync_outbox", {
        "entity": "settings",
        "operation": "upsert",
        "queuedAt": DateTime.now().toIso8601String(),
      });
    });
  }

  /// Oldest first: a stack has to exist in the cloud before the logs inside
  /// it can be written under it.
  static Future<List<Map<String, dynamic>>> pendingSyncItems({
    int limit = 200,
  }) async {
    final db = await database;

    return db.query("sync_outbox", orderBy: "id ASC", limit: limit);
  }

  static Future<int> pendingSyncCount() async {
    final db = await database;

    final rows = await db.rawQuery("SELECT COUNT(*) AS c FROM sync_outbox");
    return (rows.first["c"] as int?) ?? 0;
  }

  /// Forgets a queued upsert without queueing anything in its place.
  ///
  /// Used when a row's parent is being deleted: the parent's removal already
  /// takes the child with it in the cloud, and draining a stale upsert
  /// afterwards would recreate what was just deleted.
  static Future<void> dropQueuedUpsert(String entity, int localId) async {
    final db = await database;

    await db.delete(
      "sync_outbox",
      where: "operation = 'upsert' AND entity = ? AND localId = ?",
      whereArgs: [entity, localId],
    );
  }

  static Future<void> removeSyncItem(int id) async {
    final db = await database;
    await db.delete("sync_outbox", where: "id = ?", whereArgs: [id]);
  }

  /// Leaves the item queued and records why it did not go through, so a
  /// permanently failing entry is visible rather than retried for ever in
  /// silence.
  static Future<void> recordSyncAttempt(int id, String error) async {
    final db = await database;

    await db.rawUpdate(
      "UPDATE sync_outbox SET attempts = attempts + 1, lastError = ? "
      "WHERE id = ?",
      [error, id],
    );
  }

  static Future<void> clearOutbox() async {
    final db = await database;
    await db.delete("sync_outbox");
  }

  // --- cloud identity -------------------------------------------------------

  static Future<void> setCloudId(
    String table,
    int localId,
    String cloudId,
  ) async {
    final db = await database;

    await db.update(
      table,
      {"cloudId": cloudId},
      where: "id = ?",
      whereArgs: [localId],
    );
  }

  /// True when there is nothing on this phone worth protecting.
  ///
  /// This is what decides whether signing in restores from the cloud:
  /// restoring onto a fresh install is a rescue, restoring over existing work
  /// would be a merge, and a merge is not something to perform unasked.
  static Future<bool> isEmpty() async {
    final db = await database;

    final stacks = await db.rawQuery("SELECT COUNT(*) AS c FROM stacks");
    final logs = await db.rawQuery("SELECT COUNT(*) AS c FROM logs");

    return ((stacks.first["c"] as int?) ?? 0) == 0 &&
        ((logs.first["c"] as int?) ?? 0) == 0;
  }

  // --- users ----------------------------------------------------------------

  /// Writes the local profile record for a signed-in account.
  ///
  /// Upsert rather than insert: signing in on a phone that already knows this
  /// account must refresh the details, not fail on the primary key.
  static Future<void> saveUserProfile({
    required String uid,
    String? name,
    String? email,
    String? phone,
    String? company,
  }) async {
    final db = await database;

    await db.insert(
      "users",
      {
        "uid": uid,
        "name": _nullIfBlank(name),
        "email": _nullIfBlank(email),
        "phone": _nullIfBlank(phone),
        "company": _nullIfBlank(company),
        "createdAt": DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getUserProfile(String uid) async {
    final db = await database;

    final rows = await db.query("users", where: "uid = ?", whereArgs: [uid]);
    return rows.isEmpty ? null : rows.first;
  }

  // --- defects --------------------------------------------------------------

  static Future<int> saveDefect({
    required int logId,
    required String kind,
    double confidence = 1,
    bool automatic = false,
    double? centreX,
    double? centreY,
    double? radius,
    String? imagePath,
    String? overlayPath,
    String? severity,
  }) async {
    final db = await database;

    return db.insert("defects", {
      "logId": logId,
      "kind": kind,
      "confidence": confidence,
      "automatic": automatic ? 1 : 0,
      "severity": severity,
      "centreX": centreX,
      "centreY": centreY,
      "radius": radius,
      "imagePath": imagePath,
      "overlayPath": overlayPath,
      "createdAt": DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getDefectsForLog(int logId) async {
    final db = await database;

    return db.query(
      "defects",
      where: "logId = ?",
      whereArgs: [logId],
      orderBy: "id ASC",
    );
  }

  // --- cutting patterns -----------------------------------------------------

  /// Saves the plan chosen for a log, replacing any previous one.
  ///
  /// The requirement is explicit that a log holds at most one saved pattern
  /// and that recalculating replaces it, so the uniqueness is enforced by the
  /// schema rather than left to whoever calls this next.
  static Future<int> saveCuttingPattern({
    required int logId,
    required String strategy,
    double? boardWidthMm,
    required double boardThicknessMm,
    required double bladeThicknessMm,
    required int boardCount,
    required double yieldPercent,
    required double boardVolumeCubicFeet,
    required double wasteVolumeCubicFeet,
    required int sawPasses,
    double pricePerCubicFoot = 0,
  }) async {
    final db = await database;

    return db.insert(
      "cutting_patterns",
      {
        "logId": logId,
        "strategy": strategy,
        "boardWidthMm": boardWidthMm,
        "boardThicknessMm": boardThicknessMm,
        "bladeThicknessMm": bladeThicknessMm,
        "boardCount": boardCount,
        "yieldPercent": yieldPercent,
        "boardVolumeCubicFeet": boardVolumeCubicFeet,
        "wasteVolumeCubicFeet": wasteVolumeCubicFeet,
        "sawPasses": sawPasses,
        "pricePerCubicFoot": pricePerCubicFoot,
        "createdAt": DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getCuttingPattern(int logId) async {
    final db = await database;

    final rows = await db.query(
      "cutting_patterns",
      where: "logId = ?",
      whereArgs: [logId],
    );

    return rows.isEmpty ? null : rows.first;
  }

  // --- reports --------------------------------------------------------------

  static Future<int> saveReport({
    int? stackId,
    int? logId,
    required String format,
    required String filePath,
    double totalVolumeCubicFeet = 0,
    double totalCost = 0,
  }) async {
    final db = await database;

    return db.insert("reports", {
      "stackId": stackId,
      "logId": logId,
      "format": format,
      "filePath": filePath,
      "totalVolumeCubicFeet": totalVolumeCubicFeet,
      "totalCost": totalCost,
      "createdAt": DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getReports({int limit = 50}) async {
    final db = await database;

    return db.query("reports", orderBy: "id DESC", limit: limit);
  }

  // --- diagnostics ----------------------------------------------------------

  /// Rows kept in the diagnostic store before the oldest are discarded.
  static const int diagnosticsLimit = 200;

  /// Records an error or a timing, then trims the store back to its cap.
  ///
  /// Trimming on write rather than on read means the file cannot quietly grow
  /// for months on a phone nobody is looking at.
  static Future<void> recordDiagnostic({
    required String kind,
    required String module,
    String? code,
    String? message,
    int? durationMs,
  }) async {
    final db = await database;

    await db.insert("diagnostics", {
      "kind": kind,
      "module": module,
      "code": code,
      "message": message,
      "durationMs": durationMs,
      "createdAt": DateTime.now().toIso8601String(),
    });

    await db.rawDelete(
      "DELETE FROM diagnostics WHERE id NOT IN "
      "(SELECT id FROM diagnostics ORDER BY id DESC LIMIT ?)",
      [diagnosticsLimit],
    );
  }

  static Future<List<Map<String, dynamic>>> getDiagnostics({
    int limit = 50,
  }) async {
    final db = await database;

    return db.query("diagnostics", orderBy: "id DESC", limit: limit);
  }

  // --- search ---------------------------------------------------------------

  /// Stacks matching a keyword and/or a date range.
  ///
  /// Filtering in SQL rather than in Dart so the two-second target still
  /// holds at five hundred entries: the database has the rows and an index
  /// on the primary key, and shipping every row into memory to discard most
  /// of them would get slower exactly as the user accumulates history.
  static Future<List<Map<String, dynamic>>> searchStacks({
    String? keyword,
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await database;

    final where = <String>[];
    final args = <Object?>[];

    final term = keyword?.trim();

    if (term != null && term.isNotEmpty) {
      where.add("(name LIKE ? OR customerName LIKE ? OR remarks LIKE ?)");
      args.addAll(["%$term%", "%$term%", "%$term%"]);
    }

    if (from != null) {
      where.add("createdAt >= ?");
      args.add(from.toIso8601String());
    }

    if (to != null) {
      where.add("createdAt <= ?");
      args.add(to.toIso8601String());
    }

    return db.query(
      "stacks",
      where: where.isEmpty ? null : where.join(" AND "),
      whereArgs: args.isEmpty ? null : args,
      orderBy: "createdAt DESC, id DESC",
    );
  }

  // --- introspection --------------------------------------------------------

  /// The migration version this phone's database is actually on.
  ///
  /// Read from SQLite rather than from the constant above, because the
  /// interesting question is never "what does the code say" -- it is whether
  /// the migration really ran on this device.
  static Future<int> currentSchemaVersion() async {
    final db = await database;

    final rows = await db.rawQuery("PRAGMA user_version");
    return (rows.first.values.first as int?) ?? 0;
  }

  /// Every table, its columns, and how many rows are in it.
  ///
  /// Read-only, and generic on purpose: it reports what is genuinely in the
  /// file, so it cannot drift out of step with the schema the way a
  /// hand-written list would.
  static Future<List<TableSummary>> tableSummaries() async {
    final db = await database;

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' "
      "ORDER BY name",
    );

    final summaries = <TableSummary>[];

    for (final table in tables) {
      final name = table["name"] as String;

      // Identifiers cannot be bound as parameters, so the name is quoted
      // instead. It comes from sqlite_master rather than from anything a
      // user typed, and doubling any embedded quote keeps that safe.
      final quoted = '"${name.replaceAll('"', '""')}"';

      final count = await db.rawQuery("SELECT COUNT(*) AS c FROM $quoted");
      final columns = await db.rawQuery("PRAGMA table_info($quoted)");

      summaries.add(
        TableSummary(
          name: name,
          rows: (count.first["c"] as int?) ?? 0,
          columns: [
            for (final column in columns)
              "${column["name"]} ${column["type"]}".trim(),
          ],
        ),
      );
    }

    return summaries;
  }

  // --- restore --------------------------------------------------------------

  /// Writes a stack that came *down* from the cloud.
  ///
  /// Unlike [createStack] this preserves the original createdAt and totals
  /// rather than recomputing them, and records the cloud id it came from so
  /// the next upload updates that same document.
  static Future<int> insertRestoredStack(Map<String, Object?> values) async {
    final db = await database;

    return db.insert("stacks", {
      "name": values["name"],
      "totalVolume": (values["totalVolume"] as num?)?.toDouble() ?? 0,
      "totalCost": (values["totalCost"] as num?)?.toDouble() ?? 0,
      "createdAt": values["createdAt"] ?? DateTime.now().toIso8601String(),
      "customerName": _nullIfBlank(values["customerName"] as String?),
      "remarks": _nullIfBlank(values["remarks"] as String?),
      "cloudId": values["cloudId"],
    });
  }

  /// Writes a log that came down from the cloud, under whatever local id its
  /// parent stack ended up with.
  static Future<int> insertRestoredLog(
    Map<String, Object?> values, {
    int? stackId,
  }) async {
    final db = await database;

    return db.insert("logs", {
      "stackId": stackId,
      "diameter": (values["diameter"] as num?)?.toDouble() ?? 0,
      "lengthFeet": (values["lengthFeet"] as num?)?.toDouble() ?? 0,
      "volume": (values["volume"] as num?)?.toDouble() ?? 0,
      "cost": (values["cost"] as num?)?.toDouble() ?? 0,
      "createdAt": values["createdAt"] ?? DateTime.now().toIso8601String(),
      "measurementSource": values["measurementSource"],
      "rawDiameterInches": (values["rawDiameterInches"] as num?)?.toDouble(),
      "deductionInches": (values["deductionInches"] as num?)?.toDouble(),
      "diameterToleranceInches":
          (values["diameterToleranceInches"] as num?)?.toDouble(),
      "measurementQuality": values["measurementQuality"],
      "diameterProfile": values["diameterProfile"],
      "cloudId": values["cloudId"],
    });
  }

  /// Every log in the database, stacked or not -- used to back up data that
  /// predates syncing ever having worked.
  static Future<List<Map<String, dynamic>>> getAllLogs() async {
    final db = await database;
    return db.query("logs", orderBy: "id ASC");
  }

  static Future<int> createStack(
    String name,
    double totalVolume, {
    double totalCost = 0,
    String? customerName,
    String? remarks,
    String? userId,
    double? rate,
  }) async {
    final db = await database;

    return await db.insert(
      "stacks",
      {
        "name": name,
        "totalVolume": totalVolume,
        "totalCost": totalCost,
        "createdAt": DateTime.now().toIso8601String(),
        // Blank entries are stored as null, not "", so "has the user filled
        // this in?" is one check everywhere downstream.
        "customerName": _nullIfBlank(customerName),
        "remarks": _nullIfBlank(remarks),
        "userId": _nullIfBlank(userId),
        "rate": rate,
      },
    );
  }

  static String? _nullIfBlank(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static Future<void> updateStackDetails(
    int stackId, {
    String? name,
    String? customerName,
    String? remarks,
  }) async {
    final db = await database;

    await db.update(
      "stacks",
      {
        if (name != null) "name": name.trim(),
        "customerName": _nullIfBlank(customerName),
        "remarks": _nullIfBlank(remarks),
      },
      where: "id = ?",
      whereArgs: [stackId],
    );
  }

  /// Audit trail for how a log's stored diameter was arrived at. All fields
  /// are optional so every existing caller keeps working untouched; rows
  /// written before this existed simply carry nulls.
  static Map<String, Object?> _provenanceColumns({
    String? measurementSource,
    double? rawDiameterInches,
    double? deductionInches,
    double? diameterToleranceInches,
    String? measurementQuality,
    String? diameterProfile,
    String? notes,
    double? smallEndDiameter,
    double? largeEndDiameter,
  }) {
    return {
      "measurementSource": measurementSource,
      "rawDiameterInches": rawDiameterInches,
      "deductionInches": deductionInches,
      "diameterToleranceInches": diameterToleranceInches,
      "measurementQuality": measurementQuality,
      "diameterProfile": diameterProfile,
      "notes": _nullIfBlank(notes),
      // Both ends, so a taper-aware volume can be checked against a tape at
      // either end rather than only against one figure.
      "smallEndDiameter": smallEndDiameter,
      "largeEndDiameter": largeEndDiameter,
    };
  }

  static Future<void> addLog({
    required int stackId,
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
    String? measurementSource,
    double? rawDiameterInches,
    double? deductionInches,
    double? diameterToleranceInches,
    String? measurementQuality,
    String? diameterProfile,
    String? notes,
    double? smallEndDiameter,
    double? largeEndDiameter,
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
        ..._provenanceColumns(
          measurementSource: measurementSource,
          rawDiameterInches: rawDiameterInches,
          deductionInches: deductionInches,
          diameterToleranceInches: diameterToleranceInches,
          measurementQuality: measurementQuality,
          diameterProfile: diameterProfile,
          notes: notes,
          smallEndDiameter: smallEndDiameter,
          largeEndDiameter: largeEndDiameter,
        ),
      },
    );
  }

  /// Saves a log that doesn't belong to any stack.
  static Future<int> addStandaloneLog({
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
    String? measurementSource,
    double? rawDiameterInches,
    double? deductionInches,
    double? diameterToleranceInches,
    String? measurementQuality,
    String? diameterProfile,
    String? notes,
    double? smallEndDiameter,
    double? largeEndDiameter,
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
        ..._provenanceColumns(
          measurementSource: measurementSource,
          rawDiameterInches: rawDiameterInches,
          deductionInches: deductionInches,
          diameterToleranceInches: diameterToleranceInches,
          measurementQuality: measurementQuality,
          diameterProfile: diameterProfile,
          notes: notes,
          smallEndDiameter: smallEndDiameter,
          largeEndDiameter: largeEndDiameter,
        ),
      },
    );
  }

  /// Stacks belonging to [userId], or every stack when it is null.
  ///
  /// Rows written before ownership was recorded carry a null userId. Those
  /// are shown to whoever is signed in rather than hidden: they were saved on
  /// this phone by this person, and making a year of someone's work vanish
  /// because a column was added later would be indefensible.
  static Future<List<Map<String, dynamic>>> getStacks({String? userId}) async {
    final db = await database;

    return await db.query(
      "stacks",
      where: userId == null ? null : "userId IS NULL OR userId = ?",
      whereArgs: userId == null ? null : [userId],
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
    String? measurementSource,
    double? rawDiameterInches,
    double? deductionInches,
    double? diameterToleranceInches,
    String? measurementQuality,
    String? diameterProfile,
    String? notes,
    double? smallEndDiameter,
    double? largeEndDiameter,
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
          ..._provenanceColumns(
            measurementSource: measurementSource,
            rawDiameterInches: rawDiameterInches,
            deductionInches: deductionInches,
            diameterToleranceInches: diameterToleranceInches,
            measurementQuality: measurementQuality,
            diameterProfile: diameterProfile,
            notes: notes,
            smallEndDiameter: smallEndDiameter,
            largeEndDiameter: largeEndDiameter,
          ),
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
