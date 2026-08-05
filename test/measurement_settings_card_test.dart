import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartlog2/services/user_preferences_service.dart';
import 'package:smartlog2/utils/timber_volume.dart';
import 'package:smartlog2/widgets/measurement_settings_card.dart';

void main() {
  final service = UserPreferencesService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service.resetForTesting();
  });

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MeasurementSettingsCard()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders both volume methods with the current one selected',
      (tester) async {
    await service.load();
    await pumpCard(tester);

    expect(find.text("Standard Volume"), findsOneWidget);
    expect(find.text("Reference Table Volume"), findsOneWidget);

    final selected = tester
        .widgetList<RadioGroup<VolumeMethod>>(
          find.byType(RadioGroup<VolumeMethod>),
        )
        .single;

    expect(selected.groupValue, VolumeMethod.standard);
  });

  testWidgets('choosing a method persists it to preferences', (tester) async {
    await service.load();
    await pumpCard(tester);

    await tester.tap(find.text("Reference Table Volume"));
    await tester.pump();
    await tester.pump();

    expect(service.current.volumeMethod, VolumeMethod.referenceTable);
  });

  testWidgets('typing a deduction persists it', (tester) async {
    await service.load();
    await pumpCard(tester);

    await tester.enterText(find.byType(TextField), "2.5");
    await tester.pump();
    await tester.pump();

    expect(service.current.diameterDeductionInches, 2.5);
  });

  testWidgets('clearing the deduction field resets it to zero',
      (tester) async {
    await service.load();
    await service.setDiameterDeductionInches(3);
    await pumpCard(tester);

    await tester.enterText(find.byType(TextField), "");
    await tester.pump();
    await tester.pump();

    expect(service.current.diameterDeductionInches, 0);
  });

  testWidgets('an over-large typed deduction is clamped, not stored raw',
      (tester) async {
    await service.load();
    await pumpCard(tester);

    await tester.enterText(find.byType(TextField), "99");
    await tester.pump();
    await tester.pump();

    expect(
      service.current.diameterDeductionInches,
      UserPreferencesService.maxDeductionInches,
    );
  });

  testWidgets('a partially-typed decimal does not wipe the stored value',
      (tester) async {
    await service.load();
    await service.setDiameterDeductionInches(2);
    await pumpCard(tester);

    // "." alone is un-parseable; it must be ignored rather than resetting
    // the user's setting mid-keystroke.
    await tester.enterText(find.byType(TextField), ".");
    await tester.pump();
    await tester.pump();

    expect(service.current.diameterDeductionInches, 2);
  });

  testWidgets('shows an existing deduction pre-filled', (tester) async {
    SharedPreferences.setMockInitialValues({
      "flutter.diameter_deduction_inches": 1.5,
    });
    await service.load();
    await pumpCard(tester);

    expect(find.text("1.5"), findsOneWidget);
  });
}
