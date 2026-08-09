import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/services/diagnostics_service.dart';
import 'package:smartlog2/utils/password_policy.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tests written directly against the numbered functional requirements in the
/// EC04 application, so a claim in that document and the behaviour of the app
/// cannot drift apart without something here failing.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  var counter = 0;

  setUp(() async {
    await LocalDB.resetForTesting();
    LocalDB.testDatabasePath =
        "file:ec04_${counter++}?mode=memory&cache=shared";
  });

  tearDown(() async => LocalDB.resetForTesting());

  group('FR2 — password strength', () {
    test('rejects everything the rule forbids', () {
      // Firebase itself only enforces six characters, so each of these would
      // otherwise be accepted.
      expect(PasswordPolicy.validate("Ab1!"), contains("8 characters"));
      expect(PasswordPolicy.validate("abcdefg1!"), contains("capital"));
      expect(PasswordPolicy.validate("ABCDEFG1!"), contains("small"));
      expect(PasswordPolicy.validate("Abcdefgh!"), contains("number"));
      expect(PasswordPolicy.validate("Abcdefg1"), contains("symbol"));
      expect(PasswordPolicy.validate(""), isNotNull);
      expect(PasswordPolicy.validate(null), isNotNull);
    });

    test('accepts a password meeting all four classes', () {
      expect(PasswordPolicy.validate("Timber#2026"), isNull);
      expect(PasswordPolicy.isStrong("Timber#2026"), isTrue);
    });

    test('strength climbs as each rule is met', () {
      expect(PasswordPolicy.strength(""), 0);
      expect(PasswordPolicy.strength("abc"), lessThan(0.5));
      expect(PasswordPolicy.strength("Timber#2026"), 1.0);
    });
  });

  group('FR4 — local user profile record', () {
    test('a profile is stored locally, and never a password', () async {
      await LocalDB.saveUserProfile(
        uid: "uid-1",
        name: "Tech Titans",
        email: "team@example.com",
        company: "Smart Log",
      );

      final profile = await LocalDB.getUserProfile("uid-1");

      expect(profile, isNotNull);
      expect(profile!["name"], "Tech Titans");

      // The requirement is explicit that no password reaches this file.
      final tables = await LocalDB.tableSummaries();
      final users = tables.firstWhere((t) => t.name == "users");

      expect(
        users.columns.any((c) => c.toLowerCase().contains("password")),
        isFalse,
      );
    });

    test('signing in again refreshes rather than failing', () async {
      await LocalDB.saveUserProfile(uid: "uid-1", name: "Old name");
      await LocalDB.saveUserProfile(uid: "uid-1", name: "New name");

      final profile = await LocalDB.getUserProfile("uid-1");
      expect(profile!["name"], "New name");
    });
  });

  group('FR15 — defect records', () {
    test('a defect is persisted against its log', () async {
      final logId = await LocalDB.addStandaloneLog(
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );

      await LocalDB.saveDefect(
        logId: logId,
        kind: "rot",
        confidence: 0.82,
        automatic: true,
        centreX: 10,
        centreY: 12,
        radius: 3,
      );

      final defects = await LocalDB.getDefectsForLog(logId);

      expect(defects, hasLength(1));
      expect(defects.first["kind"], "rot");

      // Confidence is stored with every prediction, which is what lets the
      // cutting engine apply its 0.60 exclusion threshold afterwards.
      expect(defects.first["confidence"], 0.82);
      expect(defects.first["automatic"], 1);
    });
  });

  group('FR20 — cutting pattern records', () {
    test('a pattern is persisted with its yield and waste', () async {
      final logId = await LocalDB.addStandaloneLog(
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );

      await LocalDB.saveCuttingPattern(
        logId: logId,
        strategy: "cant",
        boardWidthMm: 150,
        boardThicknessMm: 50,
        bladeThicknessMm: 3,
        boardCount: 14,
        yieldPercent: 62.5,
        boardVolumeCubicFeet: 3.1,
        wasteVolumeCubicFeet: 1.9,
        sawPasses: 8,
      );

      final pattern = await LocalDB.getCuttingPattern(logId);

      expect(pattern!["boardCount"], 14);
      expect(pattern["yieldPercent"], 62.5);
      expect(pattern["bladeThicknessMm"], 3);
    });

    test('recalculating replaces the pattern rather than adding a rival',
        () async {
      final logId = await LocalDB.addStandaloneLog(
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
      );

      for (final count in [10, 14]) {
        await LocalDB.saveCuttingPattern(
          logId: logId,
          strategy: "live",
          boardThicknessMm: 50,
          bladeThicknessMm: 3,
          boardCount: count,
          yieldPercent: 60,
          boardVolumeCubicFeet: 3,
          wasteVolumeCubicFeet: 2,
          sawPasses: 6,
        );
      }

      // "Each log holds at most one saved cutting pattern" -- enforced by the
      // schema, not by whoever calls this next.
      final tables = await LocalDB.tableSummaries();
      expect(
        tables.firstWhere((t) => t.name == "cutting_patterns").rows,
        1,
      );

      final pattern = await LocalDB.getCuttingPattern(logId);
      expect(pattern!["boardCount"], 14);
    });
  });

  group('FR21 — search and filter', () {
    Future<void> seed() async {
      await LocalDB.createStack("Teak load", 0, customerName: "Perera");
      await LocalDB.createStack("Mahogany order", 0, remarks: "for export");
      await LocalDB.createStack("Pine offcuts", 0);
    }

    test('matches on name, customer and remarks', () async {
      await seed();

      expect(await LocalDB.searchStacks(keyword: "teak"), hasLength(1));
      expect(await LocalDB.searchStacks(keyword: "Perera"), hasLength(1));
      expect(await LocalDB.searchStacks(keyword: "export"), hasLength(1));
      expect(await LocalDB.searchStacks(keyword: "zzz"), isEmpty);
    });

    test('no filter returns everything', () async {
      await seed();
      expect(await LocalDB.searchStacks(), hasLength(3));
    });

    test('a date range excludes what falls outside it', () async {
      await seed();

      final future = DateTime.now().add(const Duration(days: 1));
      expect(await LocalDB.searchStacks(from: future), isEmpty);

      final past = DateTime.now().subtract(const Duration(days: 1));
      expect(await LocalDB.searchStacks(from: past), hasLength(3));
    });
  });

  group('FR23 — report history', () {
    test('exporting records what was produced and where it went', () async {
      await LocalDB.saveReport(
        stackId: 1,
        format: "csv",
        filePath: "/documents/report.csv",
        totalVolumeCubicFeet: 12.5,
        totalCost: 45000,
      );

      final reports = await LocalDB.getReports();

      expect(reports, hasLength(1));
      expect(reports.first["format"], "csv");
      expect(reports.first["totalCost"], 45000);
    });
  });

  group('FR24 & FR26 — diagnostics and timing', () {
    test('errors are recorded with their module', () async {
      await DiagnosticsService.instance.recordError(
        module: DiagnosticsService.moduleScan,
        error: Exception("sensor unavailable"),
        code: "no_lidar",
      );

      final entries = await LocalDB.getDiagnostics();

      expect(entries, hasLength(1));
      expect(entries.first["module"], "lidar_scan");
      expect(entries.first["code"], "no_lidar");
    });

    test('the store never grows past its cap', () async {
      // "Retains the 200 most recent entries and discards older entries."
      for (var i = 0; i < LocalDB.diagnosticsLimit + 25; i++) {
        await LocalDB.recordDiagnostic(
          kind: "timing",
          module: "cutting_optimisation",
          durationMs: i,
        );
      }

      final tables = await LocalDB.tableSummaries();
      expect(
        tables.firstWhere((t) => t.name == "diagnostics").rows,
        LocalDB.diagnosticsLimit,
      );
    });

    test('timing an operation records how long it took', () async {
      final result = await DiagnosticsService.instance.timed(
        DiagnosticsService.moduleCutting,
        () async => 42,
      );

      expect(result, 42);

      final entries = await LocalDB.getDiagnostics();
      expect(entries.first["kind"], "timing");
      expect(entries.first["durationMs"], isNotNull);
    });

    test('a failing operation still records, and still throws', () async {
      await expectLater(
        DiagnosticsService.instance.timed(
          DiagnosticsService.moduleDefects,
          () async => throw Exception("model missing"),
        ),
        throwsException,
      );

      final entries = await LocalDB.getDiagnostics();
      expect(entries.first["kind"], "error");
      expect(entries.first["module"], "defect_detection");
    });

    test('reports the 90th percentile, not the average', () async {
      // Seventeen fast runs and three slow ones. The mean is about 145ms and
      // would suggest the target is comfortably met; the 90th percentile is
      // what the requirement is actually stated against, and it reports the
      // slow tail the mean conceals.
      final samples = [
        ...List.filled(17, 10),
        ...List.filled(3, 900),
      ];

      for (final ms in samples) {
        await DiagnosticsService.instance.recordTiming(
          module: DiagnosticsService.moduleCutting,
          milliseconds: ms,
        );
      }

      final mean = samples.reduce((a, b) => a + b) / samples.length;
      expect(mean, lessThan(200));

      final p90 = await DiagnosticsService.instance.percentile90(
        DiagnosticsService.moduleCutting,
      );

      expect(p90, 900);
    });

    test('only counts timings from the module asked about', () async {
      await DiagnosticsService.instance.recordTiming(
        module: DiagnosticsService.moduleScan,
        milliseconds: 5000,
      );
      await DiagnosticsService.instance.recordTiming(
        module: DiagnosticsService.moduleCutting,
        milliseconds: 20,
      );

      // Scanning is allowed 8 seconds and cutting 5; mixing them would make
      // both numbers meaningless.
      expect(
        await DiagnosticsService.instance
            .percentile90(DiagnosticsService.moduleCutting),
        20,
      );
    });
  });

  group('SDS section 4.5.3 — the relational schema as designed', () {
    test('every entity in the SDS schema has a table', () async {
      final names = (await LocalDB.tableSummaries()).map((t) => t.name);

      // User, Stack, Log, Defect, Cutting_pattern, Report.
      expect(
        names,
        containsAll([
          "users",
          "stacks",
          "logs",
          "defects",
          "cutting_patterns",
          "reports",
        ]),
      );
    });

    test('columns the SDS specifies that were missing now exist', () async {
      final tables = await LocalDB.tableSummaries();

      String columnsOf(String table) =>
          tables.firstWhere((t) => t.name == table).columns.join(" ");

      // Log(..., notes, diameter_1, diameter_2)
      expect(columnsOf("logs"), contains("notes"));
      expect(columnsOf("logs"), contains("smallEndDiameter"));
      expect(columnsOf("logs"), contains("largeEndDiameter"));

      // Stack(..., user_id FK, rate)
      expect(columnsOf("stacks"), contains("userId"));
      expect(columnsOf("stacks"), contains("rate"));

      // Defect(..., severity)
      expect(columnsOf("defects"), contains("severity"));
    });

    test('a log carries the note the user typed with it', () async {
      final logId = await LocalDB.addStandaloneLog(
        diameter: 20,
        lengthFeet: 10,
        volume: 5,
        notes: "Slight bend, buyer accepted",
        smallEndDiameter: 19,
        largeEndDiameter: 21,
      );

      final log = await LocalDB.getLog(logId);

      expect(log!["notes"], "Slight bend, buyer accepted");
      expect(log["smallEndDiameter"], 19);
      expect(log["largeEndDiameter"], 21);
    });

    test('a user sees their own stacks and not another account\'s', () async {
      await LocalDB.createStack("Mine", 0, userId: "user-a");
      await LocalDB.createStack("Theirs", 0, userId: "user-b");

      final mine = await LocalDB.getStacks(userId: "user-a");

      expect(mine.map((r) => r["name"]), ["Mine"]);
    });

    test('stacks saved before ownership existed are not orphaned', () async {
      // Written with no userId, as every row already on a phone was.
      await LocalDB.createStack("From before", 0);
      await LocalDB.createStack("Mine", 0, userId: "user-a");

      final visible = await LocalDB.getStacks(userId: "user-a");

      // Making a year of someone's work vanish because a column was added
      // later would be indefensible.
      expect(visible, hasLength(2));
    });
  });

  group('EC04 section 3.7 — the tables the design promises', () {
    test(
        'users, stacks, logs, defects, cutting patterns and reports all '
        'exist', () async {
      final names = (await LocalDB.tableSummaries()).map((t) => t.name);

      expect(
        names,
        containsAll([
          "users",
          "stacks",
          "logs",
          "defects",
          "cutting_patterns",
          "reports",
        ]),
      );
    });

    test('the migration reaches the version this build expects', () async {
      expect(await LocalDB.currentSchemaVersion(), LocalDB.schemaVersion);
      expect(LocalDB.schemaVersion, 7);
    });
  });
}
