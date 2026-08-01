import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../util/home_widgets.dart';
import '../util/widget_payload.dart';
import 'notes_store.dart';
import 'settings_store.dart';

/// Keeps this device's home-screen widgets in step with the signed-in account's
/// notes, and folds ticks made on a widget back into the store.
///
/// Two directions, deliberately on different triggers. Publishing follows every
/// note and settings change (debounced, since edits arrive per keystroke).
/// Draining runs only at start and on resume: those are the moments a widget
/// may have changed something behind the app's back, and doing it on every
/// notification would replay ops against state they had already reached.
class HomeWidgetBridge {
  HomeWidgetBridge({
    required this.notes,
    required this.settings,
    required this.api,
    HomeWidgets? platform,
    this.debounce = _defaultDebounce,
  }) : _platform = platform ?? HomeWidgets();

  final NotesStore notes;
  final SettingsStore settings;

  /// Read for the base URL and bearer token mirrored to native widget code, so
  /// a tick can reach the server without the app running. The concrete client
  /// rather than the [Api] interface, which carries neither, matching how
  /// [AuthStore] takes it.
  final ApiClient api;

  final HomeWidgets _platform;

  /// Note edits arrive per keystroke and a pass re-encodes every published
  /// note, so coalescing aggressively costs nothing: a widget is never more
  /// than a second or two behind. Tests shorten it.
  static const Duration _defaultDebounce = Duration(milliseconds: 1500);

  final Duration debounce;

  Timer? _debounceTimer;
  bool _running = false;
  bool _dirty = false;
  bool _disposed = false;

  void start() {
    if (_disposed || !HomeWidgets.supported) return;
    notes.addListener(_schedulePass);
    settings.addListener(_schedulePass);
    // A widget may have been ticked while the app was closed.
    unawaited(syncNow());
  }

  /// Detaches listeners. Deliberately leaves the published notes in place: a
  /// widget has to keep rendering after the app is closed, which is the point.
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    notes.removeListener(_schedulePass);
    settings.removeListener(_schedulePass);
  }

  /// Wipe everything this account put on the home screen. For sign-out: the
  /// next account's notes are not this one's, and a widget left showing them
  /// would leak content across accounts.
  Future<void> clear() async {
    _debounceTimer?.cancel();
    await _platform.clearAll();
  }

  /// Drain first, then publish. For app start and for coming back to the
  /// foreground, where a tick made on a widget is waiting to be picked up.
  Future<void> syncNow() async {
    await _drain();
    await _publish();
  }

  void _schedulePass() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(_publish()));
  }

  /// Fold ticks made on a widget into the store.
  ///
  /// Each op names an absolute state, so applying one the server already took
  /// is a no-op rather than an unwanted flip. Anything that does land goes
  /// through the normal edit path, which means the pending-op queue, the
  /// server, and every other device pick it up exactly as if it had been
  /// ticked in the app.
  Future<void> _drain() async {
    if (!HomeWidgets.supported || _disposed) return;
    final ops = await _platform.pendingOps();
    if (ops.isEmpty || _disposed) return;
    for (final op in ops) {
      notes.setChecklistItemDone(op.noteId, op.itemId, op.done);
    }
    await _platform.clearOps();
    debugPrint('home widget: applied ${ops.length} queued tick(s)');
  }

  /// Republish, coalescing with a pass already in flight. Two overlapping
  /// passes would each encode the whole document and race to write it.
  Future<void> _publish() async {
    if (_disposed || !HomeWidgets.supported) return;
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
    // Publishing mid-load would blank every widget until the notes arrive. An
    // account with genuinely no notes still publishes: `loading` is what
    // separates "not ready" from "ready and empty".
    if (notes.loading) return;

    final wanted = await _platform.wantedIds();
    if (_disposed) return;

    final source = notes.notesForWidgets;
    await _platform.publish(
      notesDoc: buildWidgetNotesDoc(
        source,
        resolveColor: _colorsFor,
        keep: wanted.toSet(),
      ),
      index: buildWidgetIndex(source),
    );

    final token = api.token;
    if (token == null || token.isEmpty) {
      // Signed out from under us (a rejected session): a widget must not keep
      // a credential it can no longer use.
      await _platform.clearSession();
    } else {
      await _platform.setSession(baseUrl: api.baseUrl, token: token);
    }
  }

  /// Note colours resolve through the user's palette, which can be customized,
  /// so the widget is given the finished hex rather than a key it would have to
  /// know how to look up.
  WidgetNoteColors _colorsFor(String colorKey) {
    final light = settings.resolveColor(colorKey, Brightness.light);
    final dark = settings.resolveColor(colorKey, Brightness.dark);
    return (
      light: light == null ? null : PaletteEntry.colorToHex(light),
      dark: dark == null ? null : PaletteEntry.colorToHex(dark),
    );
  }
}
