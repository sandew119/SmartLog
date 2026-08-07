import 'package:flutter_test/flutter_test.dart';

/// Pumps until [finder] matches, or fails after [timeout].
///
/// Fixed-duration settling is unreliable for these screens: sqflite_ffi
/// does real async I/O that doesn't interleave with flutter_test's
/// fake-time zone, and when `flutter test` runs many files concurrently the
/// machine slows down enough that any hard-coded delay eventually becomes
/// flaky. Polling for the condition is stable under load and finishes as
/// soon as the UI is actually ready.
///
/// Must be called inside `tester.runAsync` so the real delays let that I/O
/// make progress.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    timeout: timeout,
    describe: reason ?? "finder to match: $finder",
  );
}

/// Pumps until [finder] matches nothing (e.g. a sheet has fully closed).
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isEmpty,
    timeout: timeout,
    describe: reason ?? "finder to disappear: $finder",
  );
}

/// Pumps until [condition] holds.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  String describe = "condition",
}) async {
  await _pumpUntil(tester, condition, timeout: timeout, describe: describe);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  required String describe,
}) async {
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    // Advance the fake clock so route transitions and animations progress.
    await tester.pump(const Duration(milliseconds: 100));

    if (condition()) {
      await _finishTransitions(tester);
      return;
    }

    // Yield to the real event loop so background I/O can complete.
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }

  // One last pump-and-check so a condition that became true on the final
  // iteration isn't reported as a timeout.
  await tester.pump(const Duration(milliseconds: 100));
  if (condition()) {
    await _finishTransitions(tester);
    return;
  }

  throw TestFailure("Timed out after $timeout waiting for $describe");
}

/// A widget existing in the tree is not the same as it being on screen: a
/// bottom sheet is present from the first frame of its slide-in, while
/// still positioned below the viewport and un-tappable. Pump past the
/// remaining transition so callers can interact with what they found.
Future<void> _finishTransitions(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await Future<void>.delayed(const Duration(milliseconds: 25));
  await tester.pump(const Duration(milliseconds: 100));
}
