import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartlog2/screens/optimal_cutting_screen.dart';

import 'support/async_pump.dart';

void main() {
  setUp(() {
    // The setup sheet remembers the last cut settings. Starting from empty
    // keeps the defaults asserted below deterministic.
    SharedPreferences.setMockInitialValues({});
  });

  /// Walks the flow as far as the open setup sheet.
  Future<void> openSetupSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: OptimalCuttingScreen()),
    );

    await pumpUntilFound(tester, find.text("Manual Measurements"));
    expect(find.text("Scan with LiDAR"), findsOneWidget);

    await tester.tap(find.text("Manual Measurements"));

    // The camera plugin has no platform implementation here, so its
    // indeterminate spinner stays mounted for the whole test -- which is
    // exactly why nothing below may use pumpAndSettle.
    await pumpUntilFound(tester, find.text("Skip photo, enter manually"));

    // The camera view now also offers a gallery photo, which pushes this
    // button below the fold on a short viewport. An explicit drag rather
    // than dragUntilVisible: a SingleChildScrollView builds all of its
    // children, so the finder matches while the button is still off-screen
    // and that helper would stop before scrolling anything.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pump();

    await tester.tap(find.text("Skip photo, enter manually"));
    await pumpUntilFound(tester, find.text("How should this log be cut?"));
  }

  testWidgets(
    'manual measurement flow: mode select -> skip photo -> setup sheet -> '
    'cutting plan',
    (WidgetTester tester) async {
      // The engine runs in a real isolate, so the whole sequence has to sit
      // inside one runAsync block for that work to actually make progress.
      await tester.runAsync(() async {
        await openSetupSheet(tester);

        expect(find.text("Log diameter"), findsOneWidget);
        expect(find.text("Log length"), findsOneWidget);

        // Exact size is the opening mode, so both board dimensions are asked
        // for. The max-yield mode drops the width field entirely.
        await _scrollTo(tester, "Board width");
        expect(find.text("Board thickness"), findsOneWidget);

        // Priced by volume, not per board: once widths vary a per-board
        // price is meaningless.
        await _scrollTo(tester, "Price per ft³ (optional)");

        await _scrollTo(tester, "Plan the cut");
        await tester.tap(find.text("Plan the cut"));

        await pumpUntilFound(tester, find.text("Cutting Plan"));

        // Both strategies are costed and offered, rather than one answer
        // being handed down.
        expect(find.text("Cant sawing"), findsOneWidget);
        expect(find.text("Live sawing"), findsOneWidget);

        // Everything below sits under the (tall) pattern, so scroll each into
        // view before asserting: the ListView only builds children near the
        // viewport.
        for (final label in [
          // Drawn on the log itself, not in an abstract circle.
          "The plan, drawn on the outline of the log.",
          "Yield",
          "Sawn timber",
          "Log volume",
          "Sawdust",
          "Saw passes",
          "What comes off this log",
          "Cut list",
          "Add to Stack",
          "Cut sheet for the sawyer (PDF)",
        ]) {
          await _scrollTo(tester, label, step: -100);
          expect(find.text(label), findsOneWidget);
        }
      });
    },
  );

  testWidgets(
    'max-yield mode asks only for a thickness',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        await openSetupSheet(tester);

        await tester.tap(find.text("Max yield"));
        await tester.pump();

        await _scrollTo(tester, "Narrowest usable board");

        // The whole point of the mode: the mill fixes the thickness and lets
        // the log decide the widths.
        expect(
          find.text("Board thickness (the only size you fix)"),
          findsOneWidget,
        );
        expect(find.text("Round widths down to (optional)"), findsOneWidget);
        expect(find.text("Board width"), findsNothing);
      });
    },
  );
}

/// Scrolls [label] into view inside the nearest real scroll view.
///
/// Deliberately not `find.byType(Scrollable).last`: a TextField carries its
/// own horizontal Scrollable, and once the sheet has text fields that one is
/// last in the tree -- so the drag went to a one-line editable box instead of
/// the list, and nothing ever scrolled.
Future<void> _scrollTo(
  WidgetTester tester,
  String label, {
  double step = -80,
}) async {
  await tester.dragUntilVisible(
    find.text(label),
    find.byType(ListView).first,
    Offset(0, step),
  );

  // dragUntilVisible finishes with a zero-duration ensureVisible jump. Until
  // a frame is pumped that jump has not been laid out, so the neighbours the
  // caller is about to assert on have not been built yet.
  await tester.pump();
}
