/// Thin wrapper over `flutter_local_notifications` for device-scheduled
/// reminders. All the decision-making lives in [reminder_schedule.dart]; this
/// file is the platform boundary — permissions, the timezone database, and
/// handing a [ReminderScheduleDiff] to the OS.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'reminder_schedule.dart';

/// Android notification channel for reminders. Created on first use by the
/// plugin; the id must stay stable or Android treats it as a new channel and
/// drops the user's sound/importance choices.
const String _channelId = 'reminders';

/// Schedules note reminders with this device's OS alarm scheduler.
///
/// Device-local by design: reminders fire without the server and without a
/// network, but only for notes this device has already synced. See the
/// disclaimer in Settings → Notifications.
class LocalNotifications {
  LocalNotifications({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  bool _initialized = false;

  /// Whether Android will let us schedule *exact* alarms. When false we still
  /// schedule, but the OS may slide delivery by several minutes — see
  /// [_scheduleMode].
  bool _exactAlarms = true;
  bool get exactAlarmsAllowed => _exactAlarms;

  /// Scheduling is native-only: the web implementation of `zonedSchedule`
  /// throws, and a browser tab can't hold an alarm while closed anyway.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Load the timezone database and initialize the plugin. Safe to call
  /// repeatedly. Returns false when this platform can't schedule at all.
  ///
  /// Reminders are scheduled in the device's own zone rather than as a fixed
  /// UTC offset, so one set for "09:00 next month" still fires at 09:00 after a
  /// DST change.
  Future<bool> ensureInitialized() async {
    if (!supported) return false;
    if (_initialized) return true;
    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Unknown zone name: `timezone` falls back to UTC, which still fires at
      // the right instant — only a DST shift near the boundary could nudge it.
    }
    // Permission prompts are deferred to [requestPermission] so nothing is
    // asked of the user until they turn the feature on.
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _initialized = true;
    return true;
  }

  /// Ask for the permissions a reminder needs, returning whether notifications
  /// may now be posted.
  ///
  /// Two separate grants on Android 13+: posting notifications, and scheduling
  /// *exact* alarms. Only the first is required — without the second, reminders
  /// still arrive, just not to the minute — so a refused exact-alarm grant
  /// downgrades rather than fails.
  Future<bool> requestPermission() async {
    if (!await ensureInitialized()) return false;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return false;
      final granted = await android.requestNotificationsPermission() ?? false;
      await _refreshExactAlarms(android, request: true);
      return granted;
    }
    final darwin = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await darwin?.requestPermissions(alert: true, sound: true) ?? false;
  }

  /// Re-read whether exact alarms are allowed, optionally prompting for them.
  /// The user can revoke the grant in system settings at any time, so this runs
  /// before every reconcile as well as at permission time.
  Future<void> _refreshExactAlarms(
    AndroidFlutterLocalNotificationsPlugin android, {
    bool request = false,
  }) async {
    var allowed = await android.canScheduleExactNotifications() ?? true;
    if (!allowed && request) {
      await android.requestExactAlarmsPermission();
      allowed = await android.canScheduleExactNotifications() ?? false;
    }
    _exactAlarms = allowed;
  }

  /// The reminders the OS currently has armed.
  Future<List<PendingReminder>> pending() async {
    if (!await ensureInitialized()) return const [];
    final requests = await _plugin.pendingNotificationRequests();
    return [
      for (final r in requests)
        (id: r.id, title: r.title, body: r.body, payload: r.payload),
    ];
  }

  /// `exactAllowWhileIdle` is what makes a reminder land on time on modern
  /// Android: plain `exact` is still subject to Doze, which can hold a
  /// notification until the device is next used. Falls back to the inexact
  /// variant when the exact-alarm grant is missing, because scheduling with
  /// `exact*` without it throws.
  AndroidScheduleMode get _scheduleMode => _exactAlarms
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'Reminders',
      channelDescription: 'Note reminders scheduled on this device',
      importance: Importance.max,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  /// Apply a reconcile plan. Each step is independent: one alarm the OS
  /// refuses must not abort the rest, so failures are swallowed per reminder
  /// and retried by the next pass.
  Future<void> apply(ReminderScheduleDiff diff) async {
    if (diff.isEmpty || !await ensureInitialized()) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) await _refreshExactAlarms(android);
    }
    for (final id in diff.cancel) {
      try {
        await _plugin.cancel(id: id);
      } catch (e) {
        // Already gone, or the platform rejected it; nothing to undo.
        debugPrint('reminder cancel $id failed: $e');
      }
    }
    for (final reminder in diff.schedule) {
      try {
        await _plugin.zonedSchedule(
          id: reminder.id,
          title: reminder.title,
          body: reminder.body,
          payload: reminder.payload,
          scheduledDate: tz.TZDateTime.from(reminder.dueUtc, tz.local),
          notificationDetails: _details,
          androidScheduleMode: _scheduleMode,
        );
      } catch (e) {
        // Left out of the OS's pending set, so the next reconcile retries it.
        // Never silent: this is the path that has to be dependable.
        debugPrint('reminder schedule ${reminder.noteId} failed: $e');
      }
    }
  }

  /// Drop every armed reminder. Used on sign-out and when the feature is turned
  /// off — a notification for someone else's notes would be a privacy leak.
  Future<void> cancelAll() async {
    if (!await ensureInitialized()) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {
      // Best effort.
    }
  }
}
