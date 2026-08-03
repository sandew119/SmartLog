import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:smartlog2/database/local_db.dart';
import 'package:smartlog2/screens/manual_calculator_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    LocalDB.testDatabasePath = join(
      Directory.systemTemp.path,
      "smartlog_manual_calc_test_${DateTime.now().microsecondsSinceEpoch}.db",
    );
  });

  testWidgets(
    'standalone flow: skip the stack chooser, enter two logs, both save '
    'and a fresh row is always ready',
    (WidgetTester tester) async {
      // sqflite_common_ffi does real async I/O that doesn't interleave
      // with flutter_test's fake-time-pumped zone -- the whole interaction
      // sequence has to run inside one runAsync block so real I/O can
      // actually progress between pumps.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: ManualCalculatorScreen()),
        );

        await tester.pump(const Duration(milliseconds: 300));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 300));

        // The upfront chooser sheet should be showing.
        expect(find.text("Start a Stack?"), findsOneWidget);

        await tester.tap(find.text("Continue Without a Stack"));
        await tester.pump(const Duration(milliseconds: 300));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text("Saving logs individually"), findsOneWidget);
        expect(
          find.byType(TextField),
          findsNWidgets(3),
        ); // diameter, length, price

        Future<void> commitRow(String diameter, String length) async {
          // TextField order in the tree: [0] = the toolbar's "Price/ft³"
          // field, [1] = the active row's diameter field, [2] = its length
          // field.
          final diameterField = find.byType(TextField).at(1);
          final lengthField = find.byType(TextField).at(2);

          await tester.enterText(diameterField, diameter);
          await tester.pump();
          await tester.enterText(lengthField, length);
          await tester.pump();

          // Tap the row's own confirm button rather than simulating a
          // keyboard IME submit action, which is unreliable to drive here.
          await tester.tap(find.byIcon(Icons.check_circle));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 300));
        }

        await commitRow("12", "8");

        // First row committed -- its volume is now shown as static text
        // (the toolbar's "Price/ft³" label also matches "ft³", hence >=1
        // rather than an exact count), and a fresh empty row is ready for
        // the next log.
        expect(find.textContaining("ft³"), findsWidgets);
        expect(find.byIcon(Icons.delete_outline), findsOneWidget);
        expect(find.byType(TextField), findsNWidgets(3));

        await commitRow("10", "6");

        // Two committed rows (each showing a delete icon) plus one fresh
        // row.
        expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
        expect(find.byType(TextField), findsNWidgets(3));
      });
    },
  );
}
