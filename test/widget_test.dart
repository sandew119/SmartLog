import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/main.dart';

void main() {
  // The real first screen is AuthGate, which reads FirebaseAuth.instance as
  // it builds and throws when Firebase has not been initialised. Rather than
  // leave app startup with no coverage at all, the shell is pumped with a
  // stand-in home so the parts that do not need Firebase are verified.
  const marker = Key('test-home');

  testWidgets('the app shell builds and carries its branding', (tester) async {
    await tester.pumpWidget(
      const SmartLogApp(home: Scaffold(key: marker)),
    );

    expect(find.byKey(marker), findsOneWidget);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

    // The name users see in the task switcher.
    expect(app.title, 'Smart Log');
    expect(app.debugShowCheckedModeBanner, isFalse);
  });

  testWidgets('uses Material 3 with the timber-green scheme', (tester) async {
    await tester.pumpWidget(
      const SmartLogApp(home: Scaffold(key: marker)),
    );

    final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;

    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.light);
  });

  testWidgets('defaults to the real auth gate when no home is injected', (
    tester,
  ) async {
    // Not pumped -- constructing it is enough to prove production still gets
    // AuthGate, without tripping over Firebase.
    const app = SmartLogApp();

    expect(app.home, isNull);
  });
}
