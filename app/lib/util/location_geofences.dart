import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:native_geofence/native_geofence.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_location.dart';
import 'location_reminder_schedule.dart';
import 'reminder_schedule.dart';

const String _metadataKey = 'skippy_location_geofence_metadata';
const String _firedKey = 'skippy_location_geofence_fired';
const String _repeatFiredKey = 'skippy_location_geofence_repeat_fired';
const String _channelId = 'location_reminders';

/// Runs in the plugin's background isolate, including when the app was
/// terminated. Metadata is copied into device preferences during reconcile so
/// this callback never needs a token, database, or network connection.
@pragma('vm:entry-point')
Future<void> locationGeofenceTriggered(GeofenceCallbackParams params) async {
  DartPluginRegistrant.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final metadata = _readMetadata(prefs);
  final fired = prefs.getStringList(_firedKey)?.toSet() ?? <String>{};
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ),
  );

  final recent = _readRepeatFires(prefs);
  for (final geofence in params.geofences) {
    final raw = metadata[geofence.id];
    if (raw is! Map<String, dynamic>) continue;
    final noteId = raw['note_id'] as String?;
    if (noteId == null || noteId.isEmpty) continue;
    final expected = LocationReminderTrigger.fromWire(
      raw['trigger'] as String?,
    );
    final matches = switch (params.event) {
      GeofenceEvent.enter => expected == LocationReminderTrigger.arrive,
      GeofenceEvent.exit => expected == LocationReminderTrigger.leave,
      GeofenceEvent.dwell => false,
    };
    if (!matches) continue;
    final repeats = raw['repeats'] == true;

    if (repeats) {
      // Deliberately not added to the fired list: that list is how the app
      // learns which reminders to delete, and this one has to stay armed.
      final now = DateTime.now();
      if (locationReminderMuted(recent, noteId, now)) continue;
      recent[noteId] = now.millisecondsSinceEpoch;
      await prefs.setString(
        _repeatFiredKey,
        jsonEncode(prunedRepeatFires(recent, now)),
      );
    } else {
      if (fired.contains(noteId)) continue;
      fired.add(noteId);
      metadata.remove(geofence.id);
      await prefs.setStringList(_firedKey, fired.toList());
      await prefs.setString(_metadataKey, jsonEncode(metadata));
    }

    final place = raw['place'] as String? ?? 'saved place';
    final action = expected == LocationReminderTrigger.arrive
        ? 'Arrived at $place'
        : 'Left $place';
    final noteBody = (raw['body'] as String? ?? '').trim();
    await notifications.show(
      id: reminderNotificationId(noteId),
      title: raw['title'] as String? ?? 'Reminder',
      body: noteBody.isEmpty ? action : '$action · $noteBody',
      payload: 'skippy-reminder:$noteId',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Location reminders',
          channelDescription: 'Note reminders triggered at saved places',
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          interruptionLevel: InterruptionLevel.active,
        ),
      ),
    );

    if (repeats) continue;
    try {
      await NativeGeofenceManager.instance.initialize();
      await NativeGeofenceManager.instance.removeGeofenceById(geofence.id);
    } catch (error) {
      debugPrint('location reminder cleanup failed: $error');
    }
  }
}

Map<String, dynamic> _readRepeatFires(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(_repeatFiredKey);
    final decoded = raw == null ? null : jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

Map<String, dynamic> _readMetadata(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(_metadataKey);
    final decoded = raw == null ? null : jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// Native boundary for registering personal location reminders.
class LocationGeofences {
  LocationGeofences._();

  static final LocationGeofences instance = LocationGeofences._();

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool _initialized = false;

  Future<void> _initialize() async {
    if (!supported || _initialized) return;
    await NativeGeofenceManager.instance.initialize();
    _initialized = true;
  }

  /// Requests the foreground grant first because both mobile systems require
  /// that step before they will offer always/background access.
  Future<bool> requestReminderPermissions() async {
    if (!supported) return false;
    var notifications = await Permission.notification.status;
    if (!notifications.isGranted) {
      notifications = await Permission.notification.request();
    }
    if (!notifications.isGranted) return false;
    var foreground = await Permission.locationWhenInUse.status;
    if (!foreground.isGranted) {
      foreground = await Permission.locationWhenInUse.request();
    }
    if (!foreground.isGranted) return false;
    var background = await Permission.locationAlways.status;
    if (!background.isGranted) {
      background = await Permission.locationAlways.request();
    }
    return background.isGranted;
  }

  /// A foreground-only fix used to create a named place in Settings.
  Future<({double latitude, double longitude})?> currentPosition() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return null;
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      return null;
    }
    final position = await geo.Geolocator.getCurrentPosition(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return (latitude: position.latitude, longitude: position.longitude);
  }

  Future<Set<String>> consumeFiredNoteIds() async {
    final prefs = await SharedPreferences.getInstance();
    final result = prefs.getStringList(_firedKey)?.toSet() ?? <String>{};
    if (result.isNotEmpty) await prefs.remove(_firedKey);
    return result;
  }

  Future<void> reconcile(List<PlannedLocationReminder> desired) async {
    if (!supported) return;
    await _initialize();
    final manager = NativeGeofenceManager.instance;
    final active = await manager.getRegisteredGeofences();
    final activeById = {for (final geofence in active) geofence.id: geofence};
    final desiredIds = {for (final reminder in desired) reminder.geofenceId};

    for (final geofence in active) {
      if (geofence.id.startsWith(kLocationGeofencePrefix) &&
          !desiredIds.contains(geofence.id)) {
        await manager.removeGeofenceById(geofence.id);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final metadata = <String, dynamic>{};
    for (final reminder in desired) {
      metadata[reminder.geofenceId] = {
        'note_id': reminder.noteId,
        'title': reminder.title,
        'body': reminder.body,
        'place': reminder.location.name,
        'trigger': reminder.trigger.wire,
        'repeats': reminder.repeats,
      };
    }
    await prefs.setString(_metadataKey, jsonEncode(metadata));

    for (final reminder in desired) {
      final event = reminder.trigger == LocationReminderTrigger.arrive
          ? GeofenceEvent.enter
          : GeofenceEvent.exit;
      final existing = activeById[reminder.geofenceId];
      final unchanged =
          existing != null &&
          (existing.location.latitude - reminder.location.latitude).abs() <
              0.0000001 &&
          (existing.location.longitude - reminder.location.longitude).abs() <
              0.0000001 &&
          (existing.radiusMeters - reminder.location.radiusMeters).abs() <
              0.1 &&
          existing.triggers.length == 1 &&
          existing.triggers.contains(event);
      if (unchanged) continue;
      if (existing != null) {
        await manager.removeGeofenceById(reminder.geofenceId);
      }
      await manager.createGeofence(
        Geofence(
          id: reminder.geofenceId,
          location: Location(
            latitude: reminder.location.latitude,
            longitude: reminder.location.longitude,
          ),
          radiusMeters: reminder.location.radiusMeters,
          triggers: {event},
          iosSettings: const IosGeofenceSettings(initialTrigger: false),
          androidSettings: const AndroidGeofenceSettings(
            initialTriggers: {},
            notificationResponsiveness: Duration(minutes: 1),
          ),
        ),
        locationGeofenceTriggered,
      );
    }
  }

  Future<void> clear() async {
    if (!supported) return;
    try {
      await _initialize();
      final manager = NativeGeofenceManager.instance;
      final ids = await manager.getRegisteredGeofenceIds();
      for (final id in ids) {
        if (id.startsWith(kLocationGeofencePrefix)) {
          await manager.removeGeofenceById(id);
        }
      }
    } catch (error) {
      debugPrint('location reminder clear failed: $error');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_metadataKey);
    await prefs.remove(_firedKey);
  }
}
