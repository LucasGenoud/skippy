import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/models/note.dart';
import 'package:skippy/models/saved_location.dart';
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

    testWidgets('applies the selected recurrence to a quick preset', (
      tester,
    ) async {
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ReminderSelection? result;
      await pumpPicker(tester, onResult: (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('reminder-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every week').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('reminder-preset-tomorrow-morning')),
      );
      await tester.pumpAndSettle();

      expect(result?.repeat, ReminderRepeat.weekly);
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

    testWidgets('custom picker defaults to right now, not tomorrow', (
      tester,
    ) async {
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ReminderSelection? result;
      await pumpPicker(tester, onResult: (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('custom-reminder-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('save-custom-reminder')));
      await tester.pumpAndSettle();
      expect(result?.at, now);
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

    testWidgets('selects a saved place and departure trigger', (tester) async {
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
                    current: null,
                    use24hTime: true,
                    locationMonitored: true,
                    savedLocations: const [
                      SavedLocation(
                        id: 'home',
                        name: 'Home',
                        latitude: 46.948,
                        longitude: 7.4474,
                      ),
                    ],
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
      await tester.tap(find.text('At a place'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('When I leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-location-reminder')));
      await tester.pumpAndSettle();

      expect(result?.locationId, 'home');
      expect(result?.locationTrigger, LocationReminderTrigger.leave);
      expect(result?.locationRepeats, isFalse);
      expect(result?.at, isNull);
    });

    testWidgets('a saved place can remind on every visit, not just the next', (
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
                    current: null,
                    use24hTime: true,
                    locationMonitored: true,
                    savedLocations: const [
                      SavedLocation(
                        id: 'home',
                        name: 'Home',
                        latitude: 46.948,
                        longitude: 7.4474,
                      ),
                    ],
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
      await tester.tap(find.text('At a place'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every time'));
      await tester.pumpAndSettle();

      expect(
        find.text('Stays on the note and reminds you on every visit.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('save-location-reminder')));
      await tester.pumpAndSettle();

      expect(result?.locationRepeats, isTrue);
      expect(result?.locationTrigger, LocationReminderTrigger.arrive);
    });
  });

  group('desktop ReminderPicker', () {
    const desktopSize = Size(1280, 900);
    final now = DateTime(2026, 7, 28, 14, 23);
    const home = SavedLocation(
      id: 'home',
      name: 'Home',
      latitude: 46.948,
      longitude: 7.4474,
    );

    /// Opens the picker and hands back the box its result lands in.
    Future<List<ReminderSelection?>> pumpPicker(
      WidgetTester tester, {
      DateTime? current,
      LocationReminder? currentLocation,
      List<SavedLocation> savedLocations = const [],
      bool locationMonitored = false,
    }) async {
      tester.view.physicalSize = desktopSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final results = <ReminderSelection?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  results.add(
                    await ReminderPicker.show(
                      context,
                      current: current,
                      currentLocation: currentLocation,
                      savedLocations: savedLocations,
                      locationMonitored: locationMonitored,
                      use24hTime: true,
                      clock: () => now,
                    ),
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
      return results;
    }

    testWidgets('sets a reminder from one surface, not a chain of dialogs', (
      tester,
    ) async {
      // A wide layout used to walk through a kind sheet, a date dialog, a time
      // dialog and a repeat sheet to say "tomorrow morning".
      final results = await pumpPicker(tester);

      expect(find.text('Set reminder'), findsOneWidget);
      expect(find.text('Quick add'), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.byType(TimePickerDialog), findsNothing);

      await tester.tap(find.byKey(const ValueKey('reminder-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every week').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('reminder-preset-tomorrow-morning')),
      );
      await tester.pumpAndSettle();

      expect(results.single?.at, DateTime(2026, 7, 29, 9));
      expect(results.single?.repeat, ReminderRepeat.weekly);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('picks a custom date on a calendar, in place', (tester) async {
      await pumpPicker(tester);
      await tester.tap(find.byKey(const ValueKey('custom-reminder-toggle')));
      await tester.pumpAndSettle();

      // The calendar is part of the sheet, not another route on top of it.
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.byType(CupertinoDatePicker), findsNothing);
      expect(find.text('At 14:23'), findsOneWidget);
    });

    testWidgets('a place can be set where nothing watches for it', (
      tester,
    ) async {
      // The reminder lives in the account's settings, so a desktop sets one
      // and the phone is what fires it.
      final results = await pumpPicker(tester, savedLocations: const [home]);

      await tester.tap(find.text('At a place'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Watched for by Skippy on your phone'),
        findsOneWidget,
      );

      await tester.tap(find.text('When I leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-location-reminder')));
      await tester.pumpAndSettle();

      expect(results.single?.locationId, 'home');
      expect(results.single?.locationTrigger, LocationReminderTrigger.leave);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('editing a place reminder opens on the place it has', (
      tester,
    ) async {
      await pumpPicker(
        tester,
        savedLocations: const [home],
        currentLocation: const LocationReminder(
          noteId: 'n1',
          locationId: 'home',
          trigger: LocationReminderTrigger.leave,
          repeats: true,
        ),
        locationMonitored: true,
      );

      // Straight onto the place pane, showing what the note already has.
      expect(find.text('Currently every time you leave at Home'), findsOne);
      expect(find.byKey(const ValueKey('save-location-reminder')), findsOne);
      expect(find.byKey(const ValueKey('remove-reminder')), findsOne);
      expect(
        find.text('Stays on the note and reminds you on every visit.'),
        findsOneWidget,
      );
      // Nothing about a phone: this device is the one watching.
      expect(
        find.textContaining('Watched for by Skippy on your phone'),
        findsNothing,
      );
    });
  });
}
