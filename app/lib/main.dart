import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'state/auth_store.dart';
import 'state/local_cache.dart';
import 'state/notes_store.dart';
import 'state/settings_store.dart';
import 'theme.dart';
import 'util/snack.dart';

void main() {
  runApp(const StickyNotesApp());
}

class StickyNotesApp extends StatefulWidget {
  const StickyNotesApp({super.key});

  @override
  State<StickyNotesApp> createState() => _StickyNotesAppState();
}

class _StickyNotesAppState extends State<StickyNotesApp> {
  late final ApiClient _api = ApiClient();
  late final AuthStore _auth = AuthStore(api: _api);

  /// Live above the MaterialApp so that pushed routes (editor, dialogs) can
  /// read them; created per signed-in user, torn down on sign-out.
  NotesStore? _store;
  SettingsStore? _settings;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuthChanged);
    _auth.loadSavedUrls().then((_) => _auth.restore());
  }

  void _onAuthChanged() {
    final signedIn = _auth.status == AuthStatus.signedIn;
    final userId = _auth.user?.id;
    if (signedIn && (_store == null || _store!.currentUserId != userId)) {
      _store?.dispose();
      _settings?.dispose();
      _settings = SettingsStore(api: _api)..load();
      final settings = _settings!;
      _store =
          NotesStore(
              api: _api,
              cache: PrefsLocalCache(),
              currentUserId: userId,
              // Settings changes on other devices arrive on the same socket.
              onRemoteChange: () => settings.load(),
            )
            ..load()
            ..startSync();
      setState(() {});
    } else if (!signedIn && _store != null) {
      _store!.dispose();
      _settings?.dispose();
      _store = null;
      _settings = null;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
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
        if (store != null) ChangeNotifierProvider.value(value: store),
        if (settings != null) ChangeNotifierProvider.value(value: settings),
      ],
      child: ListenableBuilder(
        listenable: Listenable.merge([?settings]),
        builder: (context, _) => MaterialApp(
          title: 'Sticky Notes',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: scaffoldMessengerKey,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: settings?.themeMode ?? ThemeMode.system,
          home: Consumer<AuthStore>(
            builder: (context, auth, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
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
                      : HomeScreen(key: ValueKey(store.currentUserId)),
              },
            ),
          ),
        ),
      ),
    );
  }
}
