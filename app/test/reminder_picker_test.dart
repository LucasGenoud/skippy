import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/reminder_picker.dart';

void main() {
  group('reminderPresets', () {
    test('offers predictable quick reminder times', () {
      final now = DateTime(2026, 7, 28, 14, 23); // Tuesday
      final presets = {
        for (final preset in reminderPresets(now)) preset.id: preset.at,
      };

      expect(presets['tomorrow-morning'], DateTime(2026, 7, 29, 9));
      expect(presets['tomorrow-noon'], DateTime(2026, 7, 29, 12));
      expect(presets['tomorrow-evening'], DateTime(2026, 7, 29, 18));
      expect(presets['next-week'], DateTime(2026, 8, 3, 9));
      expect(presets['in-seven-days'], DateTime(2026, 8, 4, 14, 23));
    });

    test('next week means the following Monday when today is Monday', () {
      final presets = {
        for (final preset in reminderPresets(DateTime(2026, 8, 3, 8)))
          preset.id: preset.at,
      };

      expect(presets['next-week'], DateTime(2026, 8, 10, 9));
    });
  });

  group('mobile ReminderPicker', () {
    const phoneSize = Size(390, 844);
    final now = DateTime(2026, 7, 28, 14, 23);

    Future<void> pumpPicker(
      WidgetTester tester, {
      DateTime? current,
      bool use24hTime = true,
      ValueChanged<ReminderSelection?>? onResult,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  final result = await ReminderPicker.show(
                    context,
                    current: current,
                    use24hTime: use24hTime,
                    clock: () => now,
                  );
                  onResult?.call(result);
                },
                child: const Text('Open reminder'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open reminder'));
      await tester.pumpAndSettle();
    }

    testWidgets('uses one sheet and applies a quick preset', (tester) async {
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ReminderSelection? result;
      await pumpPicker(tester, onResult: (value) => result = value);

      expect(find.text('Set reminder'), findsOneWidget);
      expect(find.text('Quick add'), findsOneWidget);
      expect(find.text('Tomorrow morning'), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.byType(TimePickerDialog), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('reminder-preset-tomorrow-morning')),
      );
      await tester.pumpAndSettle();
      expect(result?.at, DateTime(2026, 7, 29, 9));
    });

    testWidgets('keeps custom date and time inside the same sheet', (
      tester,
    ) async {
      const compactPhoneSize = Size(390, 640);
      tester.view.physicalSize = compactPhoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpPicker(tester, use24hTime: false);
      await tester.ensureVisible(
        find.byKey(const ValueKey('custom-reminder-toggle')),
      );
      await tester.tap(find.byKey(const ValueKey('custom-reminder-toggle')));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoDatePicker), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(find.text('Save reminder'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-custom-reminder')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester
            .getBottomRight(find.byKey(const ValueKey('save-custom-reminder')))
            .dy,
        lessThan(compactPhoneSize.height - 24),
      );
      expect(find.text('Tomorrow morning'), findsNothing);
    });

    testWidgets('can remove an existing reminder from the sheet', (
      tester,
    ) async {
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ReminderSelection? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await ReminderPicker.show(
                    context,
                    current: DateTime(2026, 7, 29, 9),
                    use24hTime: true,
                    clock: () => now,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('remove-reminder')));
      await tester.tap(find.byKey(const ValueKey('remove-reminder')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.at, isNull);
    });
  });
}
