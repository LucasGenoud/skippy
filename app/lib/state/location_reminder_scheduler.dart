import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/location_geofences.dart';
import '../util/location_reminder_schedule.dart';
import 'notes_store.dart';
import 'settings_store.dart';

/// Mirrors the signed-in user's personal place reminders into OS geofences.
class LocationReminderScheduler {
  LocationReminderScheduler({
    required this.notes,
    required this.settings,
    LocationGeofences? platform,
  }) : _platform = platform ?? LocationGeofences.instance;

  final NotesStore notes;
  final SettingsStore settings;
  final LocationGeofences _platform;

  Timer? _debounce;
  bool _running = false;
  bool _dirty = false;
  bool _disposed = false;

  void start() {
    if (!LocationGeofences.supported) return;
    notes.addListener(_schedule);
    settings.addListener(_schedule);
    _schedule();
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    notes.removeListener(_schedule);
    settings.removeListener(_schedule);
  }

  void _schedule() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), reconcile);
  }

  Future<void> reconcile() async {
    if (_disposed) return;
    _dirty = true;
    if (_running) return;
    _running = true;
    try {
      while (_dirty && !_disposed) {
        _dirty = false;
        final fired = await _platform.consumeFiredNoteIds();
        if (_disposed) return;
        if (fired.isNotEmpty) settings.removeLocationReminders(fired);
        final desired = plannedLocationReminders(
          reminders: settings.locationReminders,
          locations: settings.savedLocations,
          notes: notes.notesForWidgets,
        );
        try {
          await _platform.reconcile(desired);
        } catch (error) {
          debugPrint('location reminder reconcile failed: $error');
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> clear() => _platform.clear();
}
