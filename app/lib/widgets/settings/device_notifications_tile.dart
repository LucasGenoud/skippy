import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/settings_store.dart';
import '../../util/local_notifications.dart';
import '../../util/snack.dart';

/// Toggle for reminders scheduled by this device's OS, with the caveat spelled
/// out rather than buried: unlike the server-pushed channels above, a
/// device-scheduled reminder only exists for notes this device has synced.
///
/// Renders nothing where scheduling is impossible (web), so the toggle never
/// promises something the platform can't do.
class DeviceNotificationsTile extends StatefulWidget {
  const DeviceNotificationsTile({super.key});

  @override
  State<DeviceNotificationsTile> createState() =>
      _DeviceNotificationsTileState();
}

class _DeviceNotificationsTileState extends State<DeviceNotificationsTile> {
  /// True while the system permission sheet is up, so a double tap can't fire
  /// two requests.
  bool _requesting = false;

  /// Set when Android is withholding the exact-alarm grant, which downgrades
  /// delivery to "within a few minutes" instead of on the dot.
  bool _inexact = false;

  @override
  void initState() {
    super.initState();
    if (context.read<SettingsStore>().deviceNotificationsEnabled) {
      _refreshExactness();
    }
  }

  /// Reflect the current exact-alarm state. The user can revoke it in system
  /// settings while the app is backgrounded, so this is read rather than
  /// remembered.
  Future<void> _refreshExactness() async {
    final platform = context.read<LocalNotifications>();
    await platform.ensureInitialized();
    if (!mounted) return;
    setState(() => _inexact = !platform.exactAlarmsAllowed);
  }

  Future<void> _onChanged(bool value) async {
    final settings = context.read<SettingsStore>();
    if (!value) {
      settings.setDeviceNotificationsEnabled(false);
      setState(() => _inexact = false);
      return;
    }
    if (_requesting) return;
    setState(() => _requesting = true);
    final granted = await context.read<LocalNotifications>().requestPermission();
    if (!mounted) return;
    setState(() => _requesting = false);
    if (!granted) {
      // Leave the switch off: claiming it's on while the OS drops every
      // notification would be the worst of both worlds.
      showAppSnack(
        'Notifications are blocked for Skippy. Allow them in your system '
        'settings, then try again.',
        icon: Icons.notifications_off_outlined,
        kind: SnackKind.warning,
      );
      return;
    }
    settings.setDeviceNotificationsEnabled(true);
    await _refreshExactness();
  }

  @override
  Widget build(BuildContext context) {
    if (!LocalNotifications.supported) return const SizedBox.shrink();
    final settings = context.watch<SettingsStore>();
    final enabled = settings.deviceNotificationsEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.phone_iphone_outlined),
          title: const Text('Reminders on this device'),
          subtitle: Text(
            enabled
                ? (_inexact
                      ? 'On, may be delayed a few minutes until exact alarms '
                            'are allowed in system settings'
                      : 'On, fires without a network or a channel')
                : 'Let this device raise the notification itself, no channel '
                      'needed',
          ),
          value: enabled,
          onChanged: _requesting ? null : _onChanged,
        ),
        if (enabled) const _SyncDisclaimer(),
      ],
    );
  }
}

/// The honest limitation of device-scheduled reminders. Shown only once the
/// feature is on: before that it's noise, after that it's the one thing a user
/// needs to know to trust (or not trust) what they just enabled.
class _SyncDisclaimer extends StatelessWidget {
  const _SyncDisclaimer();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'This device can only ring for reminders it already knows '
                'about. A reminder you set on another device arrives the next '
                'time Skippy syncs here, so if this app stays closed until '
                'after it was due, it will not ring. Add a notification '
                'channel above for delivery that does not depend on this '
                'device.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
