import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/local_notifications.dart';
import '../util/reminder_schedule.dart';
import 'notes_store.dart';
import 'settings_store.dart';

/// Keeps this device's OS alarms in step with the notes that carry reminders.
///
/// Reconciles against what the OS reports as pending rather than tracking its
/// own state, so every trigger — a note edit, a sync, an app resume, a cold
/// start after reboot — converges on the same correct set. Missing an alarm is
/// the failure that matters here, so passes are cheap and frequent rather than
/// clever.
class ReminderScheduler {
  ReminderScheduler({
    required this.notes,
    required this.settings,
    LocalNotifications? platform,
  }) : _platform = platform ?? LocalNotifications();

  final NotesStore notes;
  final SettingsStore settings;
  final LocalNotifications _platform;

  /// Note edits arrive per keystroke; a reminder is minutes away at the
  /// soonest, so coalescing aggressively costs nothing.
  static const Duration _debounce = Duration(milliseconds: 1500);

  Timer? _debounceTimer;
  bool _running = false;
  bool _dirty = false;
  bool _disposed = false;

  /// Tracks the on/off transition so turning the feature off clears alarms
  /// exactly once instead of on every notification.
  bool? _wasEnabled;

  bool get _enabled =>
      LocalNotifications.supported && settings.deviceNotificationsEnabled;

  void start() {
    if (_disposed || !LocalNotifications.supported) return;
    notes.addListener(_schedulePass);
    settings.addListener(_schedulePass);
    _schedulePass();
  }

  /// Detaches listeners. Deliberately leaves armed alarms in place — they are
  /// the whole point, and must survive the app being closed.
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    notes.removeListener(_schedulePass);
    settings.removeListener(_schedulePass);
  }

  /// Clear every armed reminder. For sign-out: the next account's reminders are
  /// not this one's, and a stale notification would name someone else's note.
  Future<void> clear() async {
    if (!LocalNotifications.supported) return;
    _debounceTimer?.cancel();
    _wasEnabled = null;
    await _platform.cancelAll();
  }

  void _schedulePass() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, reconcile);
  }

  /// Run a pass now, coalescing with one already in flight. Reading the pending
  /// set and applying a diff is a read-modify-write, so overlapping passes
  /// would compute their plans against stale state.
  Future<void> reconcile() async {
    if (_disposed) return;
    _dirty = true;
    if (_running) return;
    _running = true;
    try {
      while (_dirty && !_disposed) {
        _dirty = false;
        await _pass();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _pass() async {
    final enabled = _enabled;
    if (enabled != _wasEnabled) {
      _wasEnabled = enabled;
      if (!enabled) {
        await _platform.cancelAll();
        return;
      }
    }
    if (!enabled) return;

    final now = DateTime.now();
    final desired = plannedReminders(notes.notesWithReminders, now: now);
    final pending = await _platform.pending();
    final diff = diffReminders(desired: desired, pending: pending, now: now);
    if (_disposed) return;
    // Debug-only, and only when something actually changes: a feature this
    // quiet is otherwise impossible to tell apart from one that never ran.
    assert(() {
      if (!diff.isEmpty) {
        debugPrint(
          'reminders: ${desired.length} planned, ${pending.length} armed, '
          'arming ${diff.schedule.length}, cancelling ${diff.cancel.length}',
        );
      }
      return true;
    }());
    await _platform.apply(diff);
  }
}
