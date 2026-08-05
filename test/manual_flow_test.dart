import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/screens/optimal_cutting_screen.dart';

void main() {
  testWidgets(
    'manual measurement flow: mode select -> skip photo -> setup sheet -> '
    'generated result',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: OptimalCuttingScreen()),
      );

      // Camera plugin has no platform implementation in the test harness,
      // so the screen should settle into its graceful "not available" state
      // rather than hanging or throwing.
      await tester.pumpAndSettle();

      expect(find.text("Scan with LiDAR"), findsOneWidget);
      expect(find.text("Manual Measurements"), findsOneWidget);

      await tester.tap(find.text("Manual Measurements"));

      // Don't use pumpAndSettle here: the camera plugin has no platform
      // implementation in the test harness, so `availableCameras()` never
      // resolves and its indeterminate CircularProgressIndicator would keep
      // pumpAndSettle from ever converging. The "Skip photo" action doesn't
      // depend on camera state resolving, so a single pump is enough.
      await tester.pump();

      expect(find.text("Skip photo, enter manually"), findsOneWidget);

      await tester.tap(find.text("Skip photo, enter manually"));
      await _pumpPastAnimations(tester);

      expect(find.text("Let's Cut This Optimally"), findsOneWidget);
      expect(find.text("Log Diameter"), findsOneWidget);
      expect(find.text("Log Length"), findsOneWidget);

      // "Generate Optimal Pattern" sits below the fold of the setup sheet's
      // scrollable content, so scroll it into view before tapping.
      await tester.dragUntilVisible(
        find.text("Generate Optimal Pattern"),
        find.byType(Scrollable).last,
        const Offset(0, -80),
      );

      // dragUntilVisible stops as soon as any part of the widget overlaps
      // the viewport, which can still leave it right at the clipped edge —
      // scroll a bit further so the tap below reliably lands on it.
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -80));
      await tester.pump();

      expect(find.text("Price per Board"), findsOneWidget);

      // Defaults are pre-filled and valid, so Generate should work as-is.
      await tester.tap(find.text("Generate Optimal Pattern"));
      await _pumpPastAnimations(tester);

      expect(find.text("Optimal Cutting Result"), findsOneWidget);
      expect(
        find.text("No photo — manual measurements only"),
        findsOneWidget,
      );

      // The result screen's stat cards sit below the (tall) pattern
      // painter, so scroll each into view before asserting on it — the
      // ListView only builds children near the current viewport.
      for (final label in [
        "Boards",
        "Yield",
        "Waste",
        "Estimated Profit",
        "Log Volume",
        "Add to Stack",
      ]) {
        await tester.dragUntilVisible(
          find.text(label),
          find.byType(Scrollable).last,
          const Offset(0, -100),
        );
        expect(find.text(label), findsOneWidget);
      }
    },
  );
}

/// Pumps enough frames to carry finite transition animations to
/// completion, without using pumpAndSettle — the underlying manual-camera
/// screen keeps an indeterminate CircularProgressIndicator mounted for the
/// whole test (the camera plugin never resolves in this harness), which
/// would make pumpAndSettle spin forever.
Future<void> _pumpPastAnimations(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
