/// Thin wrapper over `home_widget` for the home-screen widgets. All the
/// decisions about *what* to publish live in [widget_payload.dart]; this file
/// is the platform boundary: the shared store, reloading the widgets, and
/// pinning one.
///
/// Everything here is best-effort. A widget is an accessory: no failure in it
/// may ever surface as an error in the app, so calls swallow and log rather
/// than throw. The shape mirrors [LocalNotifications], including the runtime
/// [supported] gate that keeps the web build clear of a plugin with no web
/// implementation.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'widget_payload.dart';

/// The App Group shared by the app, the share extension and the widget. Already
/// provisioned on both iOS targets; iOS reads nothing without it.
const String kAppGroupId = 'group.com.lucasgenoud.skippy';

/// Names the native widget implementations register under. `updateWidget` uses
/// these to find what to reload, so they must match the Swift `kind` string and
/// the Kotlin provider class name exactly.
const String kIOSWidgetKind = 'SkippyNoteWidget';
const String kAndroidWidgetProvider =
    'com.lucasgenoud.skippy.SkippyWidgetProvider';

/// Deep link a widget tap opens, as `skippy://note/<id>?homeWidget=1`.
///
/// That query parameter is required, not cosmetic: the plugin's launch-URL
/// handlers ignore any URL without a `homeWidget` query item, so a link missing
/// it foregrounds the app and is then silently dropped.
const String kWidgetUrlScheme = 'skippy';

/// Extra query flag on the link behind a widget's "Add item" row, as
/// `skippy://note/<id>?homeWidget=1&add=1`.
///
/// Neither platform lets a home-screen widget take text input — WidgetKit has
/// no text field at all, and Android's `RemoteViews` has no editable view — so
/// adding an item cannot happen on the home screen. The row opens the note
/// instead, with an empty checklist row already focused, which is the closest
/// thing to typing straight into the widget. Native widget code appends this
/// by hand, so it is a wire contract like the store keys.
const String kWidgetAddItemParam = 'add';

/// What a tap on a home-screen widget asked the app to do: show a note, and
/// (from the "Add item" row) start a new checklist item in it.
typedef WidgetTap = ({String noteId, bool addItem});

/// Publishes notes to the device's home-screen widgets and reads back the ticks
/// they made while the app was closed.
class HomeWidgets {
  /// Widgets are a mobile-only affordance, and the plugin has no web
  /// implementation, so every call is gated rather than allowed to throw a
  /// MissingPluginException into the app.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool _appGroupSet = false;

  Future<bool> _ensureAppGroup() async {
    if (!supported) return false;
    if (_appGroupSet) return true;
    try {
      await HomeWidget.setAppGroupId(kAppGroupId);
      _appGroupSet = true;
      return true;
    } catch (e) {
      debugPrint('home widget: app group setup failed: $e');
      return false;
    }
  }

  /// Write one key. Values are JSON-encoded strings so the same encoding works
  /// on both platforms; the native side decodes with its own JSON reader.
  Future<void> _put(String key, Object? value) async {
    if (!await _ensureAppGroup()) return;
    try {
      await HomeWidget.saveWidgetData<String>(
        key,
        value == null ? null : jsonEncode(value),
      );
    } catch (e) {
      debugPrint('home widget: writing $key failed: $e');
    }
  }

  Future<Object?> _get(String key) async {
    if (!await _ensureAppGroup()) return null;
    try {
      final raw = await HomeWidget.getWidgetData<String>(key);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw);
    } catch (e) {
      // Includes a half-written document: treat as absent rather than crash the
      // pass that would have replaced it anyway.
      debugPrint('home widget: reading $key failed: $e');
      return null;
    }
  }

  /// Publish the renderable notes and the picker index, then redraw.
  Future<void> publish({
    required Map<String, dynamic> notesDoc,
    required List<Map<String, dynamic>> index,
  }) async {
    if (!supported) return;
    await _put(kWidgetNotesKey, notesDoc);
    await _put(kWidgetIndexKey, index);
    await reload();
  }

  /// Mirror the session a widget needs to sync a tick straight to the server.
  ///
  /// The bearer token is copied deliberately. Native widget code has no access
  /// to the app's own storage, and a tick that only lands when the app is next
  /// opened is not what was asked for. Both stores are private to this app and
  /// its extensions (an iOS App Group container, Android `MODE_PRIVATE`
  /// preferences), and [clearSession] wipes this on sign-out.
  Future<void> setSession({required String baseUrl, required String token}) =>
      _put(kWidgetSessionKey, {'baseUrl': baseUrl, 'token': token});

  Future<void> clearSession() => _put(kWidgetSessionKey, null);

  /// Ticks made on a widget that the server has not confirmed.
  Future<List<WidgetOp>> pendingOps() async =>
      parseWidgetOps(await _get(kWidgetOpsKey));

  /// Drop the queue once its ops have been folded into the store.
  ///
  /// Clears wholesale rather than removing the ops just read. A tick arriving
  /// between the read and this call would be lost by a naive rewrite anyway,
  /// and the widget's own copy of the note already shows the new state, so the
  /// cost of that race is bounded at one tick, not a wrong value.
  Future<void> clearOps() => _put(kWidgetOpsKey, const []);

  /// Note ids a widget wanted but could not find in the published document.
  Future<List<String>> wantedIds() async =>
      parseWantedIds(await _get(kWidgetWantedKey));

  /// Forget everything this account put on the home screen. For sign-out: the
  /// next account's notes are not this one's, and a widget must never keep
  /// showing a signed-out user's content.
  Future<void> clearAll() async {
    if (!supported) return;
    await _put(kWidgetNotesKey, {
      'version': kWidgetPayloadVersion,
      'notes': {},
    });
    await _put(kWidgetIndexKey, const []);
    await _put(kWidgetOpsKey, const []);
    await _put(kWidgetWantedKey, const []);
    await _put(kWidgetPreselectKey, null);
    await clearSession();
    await reload();
  }

  /// Ask the widgets to redraw from what was just published.
  Future<void> reload() async {
    if (!await _ensureAppGroup()) return;
    try {
      await HomeWidget.updateWidget(
        iOSName: kIOSWidgetKind,
        qualifiedAndroidName: kAndroidWidgetProvider,
      );
    } catch (e) {
      debugPrint('home widget: reload failed: $e');
    }
  }

  /// Whether this device can place a widget on the user's behalf.
  ///
  /// Android 8+ only, and never iOS: iOS gives apps no API to add a widget, so
  /// there the app can only explain how to add one by hand.
  Future<bool> canPin() async {
    if (!supported || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } catch (e) {
      debugPrint('home widget: pin support check failed: $e');
      return false;
    }
  }

  /// The note a just-pinned widget should offer first.
  ///
  /// `requestPinWidget` carries no payload, so the note the user pinned from
  /// is handed over out of band and read by the configuration screen the
  /// launcher opens next.
  Future<void> setPreselectedNote(String noteId) =>
      _put(kWidgetPreselectKey, noteId);

  /// Read and consume the preselected note, so it applies to exactly one
  /// configuration and a later hand-added widget starts from a clean picker.
  Future<String?> takePreselectedNote() async {
    final raw = await _get(kWidgetPreselectKey);
    if (raw is! String || raw.isEmpty) return null;
    await _put(kWidgetPreselectKey, null);
    return raw;
  }

  /// Ask the launcher to pin a widget. The note is chosen in the configuration
  /// screen the launcher opens, so nothing is passed here.
  Future<void> requestPin() async {
    if (!await canPin()) return;
    try {
      await HomeWidget.requestPinWidget(
        qualifiedAndroidName: kAndroidWidgetProvider,
      );
    } catch (e) {
      debugPrint('home widget: pin request failed: $e');
    }
  }

  /// The widget the launcher is waiting for us to configure, or null on a
  /// normal launch.
  ///
  /// Android only: the launcher starts the app with
  /// `ACTION_APPWIDGET_CONFIGURE` after a widget is added, and will discard the
  /// widget unless [bindWidgetToNote] finishes the flow. iOS configures widgets
  /// in its own edit sheet and never calls this.
  Future<int?> pendingConfigureWidgetId() async {
    if (!supported || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final raw = await HomeWidget.initiallyLaunchedFromHomeWidgetConfigure();
      return raw == null ? null : int.tryParse(raw);
    } catch (e) {
      debugPrint('home widget: configure check failed: $e');
      return null;
    }
  }

  /// Point one widget instance at a note and hand control back to the launcher.
  Future<void> bindWidgetToNote(int widgetId, String noteId) async {
    await _put(widgetNoteKey(widgetId), noteId);
    await _put(kWidgetPreselectKey, null);
    try {
      await HomeWidget.finishHomeWidgetConfigure();
    } catch (e) {
      debugPrint('home widget: finishing configure failed: $e');
    }
    await reload();
  }

  /// What a widget-tap deep link asked for, or null for anything else.
  static WidgetTap? tapFromUri(Uri? uri) {
    if (uri == null || uri.scheme != kWidgetUrlScheme) return null;
    // skippy://note/<id> parses as host 'note' with one path segment.
    if (uri.host != 'note') return null;
    final segments = uri.pathSegments;
    if (segments.isEmpty || segments.first.isEmpty) return null;
    return (
      noteId: segments.first,
      addItem: uri.queryParameters[kWidgetAddItemParam] == '1',
    );
  }

  /// Taps on a widget while the app is already running.
  Stream<WidgetTap?> get tappedNotes =>
      HomeWidget.widgetClicked.map(tapFromUri);

  /// The tap that launched the app from a terminated state, which never reaches
  /// [tappedNotes] because nothing was listening yet.
  Future<WidgetTap?> initialTap() async {
    if (!await _ensureAppGroup()) return null;
    try {
      return tapFromUri(await HomeWidget.initiallyLaunchedFromHomeWidget());
    } catch (e) {
      debugPrint('home widget: launch check failed: $e');
      return null;
    }
  }
}
