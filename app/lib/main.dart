import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'state/auth_store.dart';
import 'state/link_preview_cache.dart';
import 'state/local_cache.dart';
import 'state/notes_store.dart';
import 'state/settings_store.dart';
import 'state/share_intake.dart';
import 'theme.dart';
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

  /// Live above the MaterialApp so that pushed routes (editor, dialogs) can
  /// read them; created per signed-in user, torn down on sign-out.
  NotesStore? _store;
  SettingsStore? _settings;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _auth.loadSavedUrls().then((_) => _auth.restore());
    _shareIntake.start();
  }

  void _onAuthChanged() {
    final signedIn = _auth.status == AuthStatus.signedIn;
    final userId = _auth.user?.id;
    if (signedIn && (_store == null || _store!.currentUserId != userId)) {
      _store?.dispose();
      _settings?.dispose();
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
      _shareIntake.setStore(_store);
      setState(() {});
    } else if (!signedIn && _store != null) {
      _store!.dispose();
      _settings?.dispose();
      _store = null;
      _settings = null;
      _linkPreviews = null;
      _shareIntake.setStore(null);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _shareIntake.dispose();
    _store?.dispose();
    _settings?.dispose();
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
          scaffoldMessengerKey: scaffoldMessengerKey,
          builder: (context, child) => BackgroundGuard(
            onBackground: () => _store?.flushForBackground(),
            onForeground: () => _store?.onResumed(),
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
          home: Consumer<AuthStore>(
            builder: (context, auth, _) => AnimatedSwitcher(
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
            ),
          ),
        ),
      ),
    );
  }
}
