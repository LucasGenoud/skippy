import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/settings/location_map_picker.dart';

void main() {
  ({double latitude, double longitude})? moved;

  Widget picker({double latitude = 46.948, double longitude = 7.4474}) =>
      MaterialApp(
        home: Scaffold(
          body: LocationMapPicker(
            latitude: latitude,
            longitude: longitude,
            radiusMeters: 150,
            onMoved: (point) => moved = point,
          ),
        ),
      );

  setUp(() => moved = null);

  testWidgets('the pin starts on the place it was given', (tester) async {
    await tester.pumpWidget(picker());
    await tester.pump();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.options.initialCenter.latitude, closeTo(46.948, 0.000001));
    expect(map.options.initialCenter.longitude, closeTo(7.4474, 0.000001));
    expect(moved, isNull, reason: 'showing a place is not moving it');
  });

  testWidgets('dragging the map moves the place under the pin', (tester) async {
    await tester.pumpWidget(picker());
    await tester.pump();

    await tester.drag(find.byType(FlutterMap), const Offset(-60, -60));
    await tester.pumpAndSettle();

    expect(moved, isNotNull);
    // Dragging the map up and to the left walks the pin south-east over it.
    expect(moved!.latitude, lessThan(46.948));
    expect(moved!.longitude, greaterThan(7.4474));
  });

  testWidgets('tapping the map puts the pin there', (tester) async {
    await tester.pumpWidget(picker());
    await tester.pump();

    final map = tester.getRect(find.byType(FlutterMap));
    await tester.tapAt(Offset(map.center.dx + 80, map.center.dy));
    // A single tap is only a single tap once the double-tap window closes.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(moved, isNotNull);
    expect(moved!.longitude, greaterThan(7.4474));
    expect(moved!.latitude, closeTo(46.948, 0.001));
  });

  testWidgets('a coordinate typed elsewhere moves the map, silently', (
    tester,
  ) async {
    await tester.pumpWidget(picker());
    await tester.pump();

    await tester.pumpWidget(picker(latitude: 47.3769, longitude: 8.5417));
    await tester.pumpAndSettle();

    // Read the camera from inside the map, where the layers see it.
    final inside = tester.element(find.byType(CircleLayer));
    expect(MapCamera.of(inside).center.latitude, closeTo(47.3769, 0.0001));
    expect(MapCamera.of(inside).center.longitude, closeTo(8.5417, 0.0001));
    expect(
      moved,
      isNull,
      reason: 'following the fields must not write back to them',
    );
  });
}
