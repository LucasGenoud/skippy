import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'screens/editor_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/public_share_screen.dart';
import 'screens/widget_config_screen.dart';
import 'state/auth_store.dart';
import 'state/home_widget_bridge.dart';
import 'state/link_preview_cache.dart';
import 'state/local_cache.dart';
import 'state/notes_store.dart';
import 'state/reminder_scheduler.dart';
import 'state/settings_store.dart';
import 'state/share_intake.dart';
import 'theme.dart';
import 'util/home_widgets.dart';
import 'util/local_notifications.dart';
import 'util/motion.dart';
import 'util/note_routes.dart';
import 'util/public_route.dart';
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

  /// One shared handle on the home-screen widgets: [_widgets] publishes through
  /// it, and taps on a widget arrive through it here.
  late final HomeWidgets _homeWidgets = HomeWidgets();

  StreamSubscription<WidgetTap?>? _widgetTaps;

  /// Lets a notification tap push the editor from outside the widget tree
  /// that built it (the tap callback has no BuildContext of its own).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Which notes are open, so a repeat tap raises one instead of stacking it.
  final OpenNoteRoutes _openNotes = OpenNoteRoutes();

  /// Live above the MaterialApp so that pushed routes (editor, dialogs) can
  /// read them; created per signed-in user, torn down on sign-out.
  NotesStore? _store;
  SettingsStore? _settings;

  /// Mirrors the signed-in user's reminders onto this device's alarms.
  ReminderScheduler? _reminders;

  /// Mirrors the signed-in user's notes onto this device's home-screen widgets.
  HomeWidgetBridge? _widgets;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _auth.loadSavedUrls().then((_) => _auth.restore());
    _shareIntake.start();
    // Set up early (not gated on sign-in) so a tap that launched the app
    // fresh from a terminated state is captured before anything else runs.
    _localNotifications.ensureInitialized();
    _localNotifications.tappedNoteId.addListener(_onNotificationTap);
    // Same reasoning for a home-screen widget: the stream only carries taps
    // that arrive while the app runs, so a cold launch is asked about directly.
    _widgetTaps = _homeWidgets.tappedNotes.listen((tap) {
      if (tap != null) {
        _requestOpenNote(tap.noteId, addChecklistItem: tap.addItem);
      }
    });
    _homeWidgets.initialTap().then((tap) {
      if (tap != null && mounted) {
        _requestOpenNote(tap.noteId, addChecklistItem: tap.addItem);
      }
    });
    // Android only: the launcher opened us to ask which note a newly added
    // widget should show, and is holding that widget until we answer.
    _homeWidgets.pendingConfigureWidgetId().then((id) {
      if (id != null && mounted) setState(() => _configuringWidgetId = id);
    });
  }

  /// The widget the launcher is waiting for us to configure, if any.
  int? _configuringWidgetId;

  /// Set when the app was opened at a `/s/<token>` URL, which is a public
  /// share page rather than the app proper.
  ///
  /// Read once, from the URL the page loaded at, and never again: the page is
  /// a standalone reader, not a route the app navigates in and out of. It
  /// wins over the auth gate on purpose, someone following a shared link wants
  /// the shared thing whether or not they happen to be signed in here.
  late final String? _publicShareToken = kIsWeb
      ? publicShareToken(Uri.base.path)
      : null;

  /// The client the public page reads through: pinned to the origin that
  /// served the page, not to [_api].
  ///
  /// [_api] resolves its base through the signed-in app's rules (a saved
  /// server, a dart-define, an injected URL, then a same-origin guess that
  /// only fires on the default port). None of those apply to a reader who
  /// arrived from a link: the only backend that can answer for this token is
  /// the one that handed out the page, so ask that one. Caught in the browser,
  /// where a server on a non-default port left the page asking localhost:8787.
  late final ApiClient _publicApi = ApiClient(baseUrl: Uri.base.origin);

  void _onNotificationTap() {
    final noteId = _localNotifications.tappedNoteId.value;
    if (noteId != null) _requestOpenNote(noteId);
  }

  /// A note that something outside the widget tree asked to open: a tapped
  /// reminder notification, or a tapped home-screen widget. Held until the
  /// store actually has it.
  String? _pendingOpenNoteId;

  /// Whether that note should open with a fresh checklist row focused: the
  /// widget's "Add item" row, which cannot take the text itself.
  bool _pendingOpenAddItem = false;

  /// The listener waiting for [_pendingOpenNoteId] to arrive in the store, kept
  /// so a second tap replaces it rather than stacking another one.
  VoidCallback? _openRetry;

  void _requestOpenNote(String noteId, {bool addChecklistItem = false}) {
    _pendingOpenNoteId = noteId;
    _pendingOpenAddItem = addChecklistItem;
    _openPendingNote();
  }

  /// Opens the pending note. It may not have synced onto this device yet (or
  /// the store may not exist yet, on a cold start still restoring auth); either
  /// way this keeps waiting on the store rather than dropping the tap.
  void _openPendingNote() {
    final noteId = _pendingOpenNoteId;
    final store = _store;
    if (noteId == null || store == null) return;
    if (store.noteById(noteId) == null) {
      _cancelOpenRetry(store);
      void retry() {
        // Superseded by a newer tap, or already consumed some other way.
        if (_pendingOpenNoteId != noteId) {
          _cancelOpenRetry(store);
          return;
        }
        if (store.noteById(noteId) != null) {
          _cancelOpenRetry(store);
          _openPendingNote();
        }
      }

      _openRetry = retry;
      store.addListener(retry);
      return;
    }
    _cancelOpenRetry(store);
    _pendingOpenNoteId = null;
    final addItem = _pendingOpenAddItem;
    _pendingOpenAddItem = false;
    // Consume the notification tap too, so it can't replay on the next pass.
    if (_localNotifications.tappedNoteId.value == noteId) {
      _localNotifications.tappedNoteId.value = null;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    _openNotes.showNote(
      navigator,
      noteId,
      (_) => EditorScreen(noteId: noteId, addChecklistItem: addItem),
    );
  }

  void _cancelOpenRetry(NotesStore store) {
    final retry = _openRetry;
    if (retry == null) return;
    store.removeListener(retry);
    _openRetry = null;
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
      _reminders = ReminderScheduler(
        notes: _store!,
        settings: settings,
        platform: _localNotifications,
      )..start();
      _widgets = HomeWidgetBridge(
        notes: _store!,
        settings: settings,
        api: _api,
        platform: _homeWidgets,
      )..start();
      _shareIntake.setStore(_store);
      setState(() {});
      // A cold start can finish auth restore after the launch-notification
      // check already ran, so re-check now that the store exists.
      _openPendingNote();
    } else if (!signedIn && _store != null) {
      _cancelOpenRetry(_store!);
      _pendingOpenNoteId = null;
      _store!.dispose();
      _settings?.dispose();
      // Drop this account's alarms and home-screen widgets before forgetting
      // whose they were: either would otherwise keep showing their notes.
      _reminders?.clear();
      _reminders?.dispose();
      _widgets?.clear();
      _widgets?.dispose();
      _store = null;
      _settings = null;
      _reminders = null;
      _widgets = null;
      _linkPreviews = null;
      _shareIntake.setStore(null);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _localNotifications.tappedNoteId.removeListener(_onNotificationTap);
    _widgetTaps?.cancel();
    _shareIntake.dispose();
    _store?.dispose();
    _settings?.dispose();
    _reminders?.dispose();
    _widgets?.dispose();
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
          navigatorObservers: [_openNotes],
          scaffoldMessengerKey: scaffoldMessengerKey,
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            // No screen in the tree owns an AppBar consistently enough to set
            // this itself, so nothing was asserting it: the icons kept
            // whatever style the launch screen (or the last screen before a
            // background trip) happened to leave behind, which on iOS could
            // land as light-on-light over a light background. Set from the
            // resolved theme (this `context` sits inside MaterialApp's
            // AnimatedTheme, so brightness already reflects `themeMode`) on
            // every build, including the one BackgroundGuard's onForeground
            // triggers after a resume.
            value:
                (Theme.of(context).brightness == Brightness.dark
                        ? SystemUiOverlayStyle.light
                        : SystemUiOverlayStyle.dark)
                    .copyWith(statusBarColor: Colors.transparent),
            child: BackgroundGuard(
              onBackground: () => _store?.flushForBackground(),
              onForeground: () {
                _store?.onResumed();
                // Time, permissions and the device's timezone can all have moved
                // while we were away; re-arm against what the OS actually holds.
                _reminders?.reconcile();
                // A widget may have been ticked while we were away, and it is
                // holding that tick for us.
                _widgets?.syncNow();
              },
              child: child ?? const SizedBox.shrink(),
            ),
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
          home: switch (_publicShareToken) {
            final String token => PublicShareScreen(
              token: token,
              api: _publicApi,
            ),
            _ => Consumer<AuthStore>(
              builder: (context, auth, _) {
                final store = _store;
                final configuring = _configuringWidgetId;
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
                          // Answering the launcher takes precedence over the
                          // grid: it is holding a half-created widget until we do.
                          : configuring != null
                          ? WidgetConfigScreen(
                              widgetId: configuring,
                              widgets: _homeWidgets,
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
          },
        ),
      ),
    );
  }
}
