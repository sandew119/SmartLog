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

    expect(find.text("Sri Lankan Method (ගණ අඩි)"), findsOneWidget);
    expect(find.text("Standard Method"), findsOneWidget);

    final selected = tester
        .widgetList<RadioGroup<VolumeMethod>>(
          find.byType(RadioGroup<VolumeMethod>),
        )
        .single;

    // The trade's own method is what a user gets without going looking.
    expect(selected.groupValue, VolumeMethod.referenceTable);
  });

  testWidgets('choosing a method persists it to preferences', (tester) async {
    await service.load();
    await pumpCard(tester);

    await tester.tap(find.text("Standard Method"));
    await tester.pump();
    await tester.pump();

    expect(service.current.volumeMethod, VolumeMethod.standard);
  });

  testWidgets('typing a deduction persists it', (tester) async {
    await service.load();
    await pumpCard(tester);

    await tester.enterText(find.byType(TextField), "2.5");
    await tester.pump();
    await tester.pump();

    expect(service.current.girthDeductionInches, 2.5);
  });

  testWidgets('clearing the deduction field resets it to zero',
      (tester) async {
    await service.load();
    await service.setGirthDeductionInches(3);
    await pumpCard(tester);

    await tester.enterText(find.byType(TextField), "");
    await tester.pump();
    await tester.pump();

    expect(service.current.girthDeductionInches, 0);
  });

  testWidgets('an over-large typed deduction is clamped, not stored raw',
      (tester) async {
    await service.load();
    await pumpCard(tester);

    await tester.enterText(find.byType(TextField), "99");
    await tester.pump();
    await tester.pump();

    expect(
      service.current.girthDeductionInches,
      UserPreferencesService.maxDeductionInches,
    );
  });

  testWidgets('a partially-typed decimal does not wipe the stored value',
      (tester) async {
    await service.load();
    await service.setGirthDeductionInches(2);
    await pumpCard(tester);

    // "." alone is un-parseable; it must be ignored rather than resetting
    // the user's setting mid-keystroke.
    await tester.enterText(find.byType(TextField), ".");
    await tester.pump();
    await tester.pump();

    expect(service.current.girthDeductionInches, 2);
  });

  testWidgets('shows an existing deduction pre-filled', (tester) async {
    SharedPreferences.setMockInitialValues({
      "flutter.girth_deduction_inches": 1.5,
    });
    await service.load();
    await pumpCard(tester);

    expect(find.text("1.5"), findsOneWidget);
  });

  testWidgets(
    'converts a pre-girth deduction so the allowance keeps its real size',
    (tester) async {
      // The old setting was 1.5in off the diameter. Wrapped around the log
      // that is the same cut as 4.71in off the tape -- carrying the number
      // across unchanged would silently shrink the allowance to a third.
      SharedPreferences.setMockInitialValues({
        "flutter.diameter_deduction_inches": 1.5,
      });

      await service.load();
      await pumpCard(tester);

      expect(service.current.girthDeductionInches, closeTo(4.712, 0.001));
      expect(find.textContaining("4.71"), findsOneWidget);
    },
  );

  testWidgets('migrates a legacy deduction only once', (tester) async {
    SharedPreferences.setMockInitialValues({
      "flutter.diameter_deduction_inches": 1.5,
    });

    await service.load();
    // The user then clears it. A second load must respect that, not
    // resurrect the legacy value.
    await service.setGirthDeductionInches(0);
    await service.load();

    expect(service.current.girthDeductionInches, 0);
  });
}
