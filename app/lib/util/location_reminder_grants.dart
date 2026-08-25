import 'package:flutter/material.dart' show Icons;

import 'location_geofences.dart';
import 'snack.dart';

/// Asks this device for what a location reminder needs of it, which on most
/// of them is nothing at all.
///
/// A saved place and the reminder pinned to it live in the account's settings
/// document rather than on the device that wrote them, so a laptop or a
/// browser can set one perfectly well: the phone picks it up on its next sync
/// and arms the geofence there. Only the device that does the watching has
/// grants to ask for, and asking a desktop for "always" location access would
/// be asking for something it cannot offer — refusing to save without it is
/// what kept location reminders off every platform but the phone.
///
/// Answers whether the reminder may be saved, having explained itself when
/// not.
Future<bool> ensureLocationReminderGrants() async {
  if (!LocationGeofences.supported) return true;
  if (await LocationGeofences.instance.requestReminderPermissions()) {
    return true;
  }
  showAppSnack(
    'Allow notifications and “all the time” location access so this '
    'reminder can fire while Skippy is closed.',
    icon: Icons.location_disabled_outlined,
    kind: SnackKind.warning,
  );
  return false;
}
