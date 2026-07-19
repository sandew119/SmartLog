import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/main.dart';

void main() {
  testWidgets('SmartLog app loads', (WidgetTester tester) async {
    await tester.pumpWidget(
      const SmartLogApp(),
    );

    expect(find.text('SmartLog is Ready'), findsOneWidget);
  });
}