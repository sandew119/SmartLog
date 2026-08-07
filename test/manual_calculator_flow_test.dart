import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/screens/manual_calculator_screen.dart';
import 'package:smartlog2/services/user_preferences_service.dart';
import 'package:smartlog2/utils/timber_volume.dart';

import 'support/async_pump.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_manual_calc_test_${DateTime.now().microsecondsSinceEpoch}.db",
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UserPreferencesService.instance.resetForTesting();
    await UserPreferencesService.instance.load();
  });

  /// The girth field of the row at [index]. TextField order in the tree is
  /// [0] = the toolbar's "Price/ft3" field, then two per row.
  Finder girthField(int index) => find.byType(TextField).at(1 + index * 2);
  Finder lengthField(int index) => find.byType(TextField).at(2 + index * 2);

  testWidgets(
    'volume appears as the user types, with no button press at all',
    (WidgetTester tester) async {
      // sqflite_common_ffi does real async I/O that doesn't interleave with
      // flutter_test's fake-time-pumped zone -- the whole interaction
      // sequence has to run inside one runAsync block so real I/O can
      // actually progress between pumps.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));
        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));

        // Girth alone is not enough to compute anything yet.
        await tester.enterText(girthField(0), "45");
        await tester.pump();
        expect(find.text("35 adi 1 angal"), findsNothing);

        // The moment the length lands, the book value is on screen -- the
        // page-45 row for a 40ft log, to the angal.
        await tester.enterText(lengthField(0), "40");
        await tester.pump();

        expect(find.text("35 adi 1 angal"), findsWidgets);
      });
    },
  );

  testWidgets(
    'a completed row opens the next one without stealing focus',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));
        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));

        // One row: price + girth + length.
        expect(find.byType(TextField), findsNWidgets(3));

        await tester.enterText(girthField(0), "45");
        await tester.pump();
        await tester.enterText(lengthField(0), "10");
        await tester.pump();

        // A second row appeared on its own -- no "add row" tap.
        expect(find.byType(TextField), findsNWidgets(5));

        // ...but the caret stayed put, so a user still mid-entry is not
        // yanked out of the field they are typing in.
        final length = tester.widget<TextField>(lengthField(0));
        expect(length.focusNode?.hasFocus, isTrue);
      });
    },
  );

  testWidgets(
    'the running total adds every completed row in adi and angal',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));
        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));

        // 45in x 40ft -> 35 adi 1 angal (book page 45, last row).
        await tester.enterText(girthField(0), "45");
        await tester.pump();
        await tester.enterText(lengthField(0), "40");
        await tester.pump();

        expect(find.text("Total entered"), findsOneWidget);
        expect(find.text("1 log"), findsOneWidget);

        // 26in x 10ft -> 2 adi 11 angal (book page 26).
        await tester.enterText(girthField(1), "26");
        await tester.pump();
        await tester.enterText(lengthField(1), "10");
        await tester.pump();

        // Angal column: 1 + 11 = 12, which carries a whole adi and leaves 0.
        // That carry is the thing worth pinning down.
        expect(find.text("38 adi 0 angal"), findsOneWidget);
        expect(find.text("2 logs"), findsOneWidget);
      });
    },
  );

  testWidgets(
    'moving on from a finished row saves it, without a confirm tap',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));
        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));

        await tester.enterText(girthField(0), "30");
        await tester.pump();
        await tester.enterText(lengthField(0), "12");
        await tester.pump();

        // Tapping into the next row drops focus from this one, which is the
        // gesture that commits it.
        await tester.tap(girthField(1));

        await pumpUntil(
          tester,
          () => find.byIcon(Icons.delete_outline).evaluate().isNotEmpty,
          describe: "the first row to be saved",
        );

        final saved = await LocalDB.getStandaloneLogs();
        expect(saved, isNotEmpty);
      });
    },
  );

  testWidgets(
    'the explicit confirm tick still saves a row, and only once',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));
        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));

        final before = (await LocalDB.getStandaloneLogs()).length;

        await tester.enterText(girthField(0), "33");
        await tester.pump();
        await tester.enterText(lengthField(0), "9");
        await tester.pump();

        // The first row's own tick -- the auto-opened second row has one too.
        await tester.tap(find.byIcon(Icons.check_circle).first);

        await pumpUntil(
          tester,
          () => find.byIcon(Icons.delete_outline).evaluate().isNotEmpty,
          describe: "the row to be saved",
        );

        // Committing on both focus-loss and the tick must not double-write.
        final after = await LocalDB.getStandaloneLogs();
        expect(after.length, before + 1);
      });
    },
  );

  testWidgets(
    'switching to the standard method reformats the volumes shown',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await pumpUntilFound(tester, find.text("Start a Stack?"));
        await tester.tap(find.text("Continue Without a Stack"));
        await pumpUntilFound(tester, find.text("Saving logs individually"));

        await tester.enterText(girthField(0), "45");
        await tester.pump();
        await tester.enterText(lengthField(0), "40");
        await tester.pump();

        expect(find.text("35 adi 1 angal"), findsWidgets);

        // The form follows the profile setting rather than holding its own.
        await UserPreferencesService.instance.setVolumeMethod(
          VolumeMethod.standard,
        );
        await tester.pump();

        expect(find.text("35 adi 1 angal"), findsNothing);
        expect(find.text("Volume (ft³)"), findsOneWidget);
      });
    },
  );
}
