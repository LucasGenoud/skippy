import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'screens/editor_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'state/auth_store.dart';
import 'state/link_preview_cache.dart';
import 'state/local_cache.dart';
import 'state/notes_store.dart';
import 'state/reminder_scheduler.dart';
import 'state/settings_store.dart';
import 'state/share_intake.dart';
import 'theme.dart';
import 'util/local_notifications.dart';
import 'util/motion.dart';
import 'util/snack.dart';
import 'widgets/background_guard.dart';

void main() {
  runApp(const SkippyApp());
}

class SkippyApp extends StatefulWidget {
  const SkippyApp({super.key});

  @override
  State<SkippyApp> createState() => _SkippyAppState();
}

class _SkippyAppState extends State<SkippyApp> {
  late final ApiClient _api = ApiClient();
  late final AuthStore _auth = AuthStore(api: _api);

  /// Link previews can include metadata from private URLs, so this cache lives
  /// only for one authenticated server/user session.
  LinkPreviewCache? _linkPreviews;

  /// Receives content shared into the app from the OS share sheet (mobile) and
  /// creates a note for it. Long-lived so a share that arrives before sign-in
  /// queues and replays once the store exists; inert on web.
  late final ShareIntake _shareIntake = ShareIntake(
    showMessage: (msg) => showAppSnack(msg, icon: Icons.note_add_outlined),
  );

  /// One shared handle on the OS notification scheduler: the settings toggle
  /// requests permissions through it while [_reminders] schedules through it.
  late final LocalNotifications _localNotifications = LocalNotifications();

  /// Lets a notification tap push the editor from outside the widget tree
  /// that built it (the tap callback has no BuildContext of its own).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Live above the MaterialApp so that pushed routes (editor, dialogs) can
  /// read them; created per signed-in user, torn down on sign-out.
  NotesStore? _store;
  SettingsStore? _settings;

  /// Mirrors the signed-in user's reminders onto this device's alarms.
  ReminderScheduler? _reminders;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _auth.loadSavedUrls().then((_) => _auth.restore());
    _shareIntake.start();
    // Set up early (not gated on sign-in) so a tap that launched the app
    // fresh from a terminated state is captured before anything else runs.
    _localNotifications.ensureInitialized();
    _localNotifications.tappedNoteId.addListener(_openTappedNote);
  }

  /// Opens the note a reminder notification was tapped for. The note may not
  /// have synced onto this device yet (or the store may not exist yet, on a
  /// cold start still restoring auth); either way this keeps retrying against
  /// the store rather than dropping the tap.
  void _openTappedNote() {
    final noteId = _localNotifications.tappedNoteId.value;
    final store = _store;
    if (noteId == null || store == null) return;
    if (store.noteById(noteId) == null) {
      void retry() {
        // Superseded by a newer tap, or already consumed some other way.
        if (_localNotifications.tappedNoteId.value != noteId) {
          store.removeListener(retry);
          return;
        }
        if (store.noteById(noteId) != null) {
          store.removeListener(retry);
          _openTappedNote();
        }
      }

      store.addListener(retry);
      return;
    }
    _localNotifications.tappedNoteId.value = null;
    _navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => EditorScreen(noteId: noteId)),
    );
  }

  void _onAuthChanged() {
    final signedIn = _auth.status == AuthStatus.signedIn;
    final userId = _auth.user?.id;
    if (signedIn && (_store == null || _store!.currentUserId != userId)) {
      _store?.dispose();
      _settings?.dispose();
      _reminders?.dispose();
      _linkPreviews = LinkPreviewCache(api: _api);
      _settings = SettingsStore(api: _api)..load();
      final settings = _settings!;
      _store =
          NotesStore(
              api: _api,
              cache: PrefsLocalCache(),
              currentUserId: userId,
              cacheNamespace: _api.baseUrl,
              migrateLegacyCache: _auth.restoredSession,
              // Settings changes on other devices arrive on the same socket.
              onRemoteChange: () => settings.load(),
            )
            ..load()
            ..startSync();
      _reminders =
          ReminderScheduler(
              notes: _store!,
              settings: settings,
              platform: _localNotifications,
            )
            ..start();
      _shareIntake.setStore(_store);
      setState(() {});
      // A cold start can finish auth restore after the launch-notification
      // check already ran, so re-check now that the store exists.
      _openTappedNote();
    } else if (!signedIn && _store != null) {
      _store!.dispose();
      _settings?.dispose();
      // Drop this account's alarms before forgetting whose they were.
      _reminders?.clear();
      _reminders?.dispose();
      _store = null;
      _settings = null;
      _reminders = null;
      _linkPreviews = null;
      _shareIntake.setStore(null);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _localNotifications.tappedNoteId.removeListener(_openTappedNote);
    _shareIntake.dispose();
    _store?.dispose();
    _settings?.dispose();
    _reminders?.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final settings = _settings;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _auth),
        Provider<LocalNotifications>.value(value: _localNotifications),
        if (_linkPreviews != null)
          Provider<LinkPreviewCache>.value(value: _linkPreviews!),
        if (store != null) ChangeNotifierProvider.value(value: store),
        if (settings != null) ChangeNotifierProvider.value(value: settings),
      ],
      child: ListenableBuilder(
        listenable: Listenable.merge([?settings]),
        builder: (context, _) => MaterialApp(
          title: 'Skippy',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          builder: (context, child) => BackgroundGuard(
            onBackground: () => _store?.flushForBackground(),
            onForeground: () {
              _store?.onResumed();
              // Time, permissions and the device's timezone can all have moved
              // while we were away; re-arm against what the OS actually holds.
              _reminders?.reconcile();
            },
            child: child ?? const SizedBox.shrink(),
          ),
          theme: buildTheme(
            Brightness.light,
            seed: settings?.accentColor ?? kDefaultAccent,
          ),
          darkTheme: buildTheme(
            Brightness.dark,
            seed: settings?.accentColor ?? kDefaultAccent,
          ),
          themeMode: settings?.themeMode ?? ThemeMode.system,
          // Reads `_store` live instead of the `store` local above. This
          // closure builds the initial route's page, which the route caches
          // and rebuilds on its own terms, so anything captured from an
          // enclosing build can stay pinned to what it was when the route was
          // first laid down: null, leaving a permanent spinner. What does get
          // through is the AuthStore notification driving this Consumer, and
          // `_onAuthChanged` (subscribed in initState, before this Consumer
          // exists) has already set `_store` by the time it arrives.
          home: Consumer<AuthStore>(
            builder: (context, auth, _) {
              final store = _store;
              return AnimatedSwitcher(
                duration: Motion.slow,
                switchInCurve: Motion.standard,
                switchOutCurve: Motion.standard,
                child: switch (auth.status) {
                  AuthStatus.restoring => const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  ),
                  AuthStatus.signedOut => const LoginScreen(),
                  AuthStatus.signedIn =>
                    store == null
                        ? const Scaffold(
                            body: Center(child: CircularProgressIndicator()),
                          )
                        : HomeScreen(
                            key: ValueKey(
                              '${_api.baseUrl}:${store.currentUserId}',
                            ),
                          ),
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
