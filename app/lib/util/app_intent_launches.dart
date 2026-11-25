/// Launches from iOS App Intents: Siri, the Shortcuts app, Spotlight, and the
/// Control Center and Action Button controls.
///
/// They cannot reuse the widget's link plumbing. An intent runs inside the app
/// after iOS has started it, so on a cold start its link would arrive before
/// Dart is listening and be lost. Native code holds each link until [start]
/// says Dart is ready, then hands over the backlog and forwards the rest:
///
/// ```text
/// intent.perform() --> LaunchActionChannel (Swift) --pending--> start()
///                                              \---- later ---> actions
/// ```
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'launch_action.dart';

const String _channelName = 'skippy/launch_actions';
const String _readyMethod = 'ready';
const String _openMethod = 'open';

class AppIntentLaunches {
  final _channel = const MethodChannel(_channelName);
  final _actions = StreamController<LaunchAction>.broadcast();

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Intents that run while the app is already up.
  Stream<LaunchAction> get actions => _actions.stream;

  /// Listen for intents and return the ones that arrived before Dart did.
  Future<List<LaunchAction>> start() async {
    if (!_supported) {
      return const [];
    }

    // The handler goes first, so nothing falls between the backlog and it.
    _channel.setMethodCallHandler(_onCall);
    try {
      final pending = await _channel.invokeListMethod<String>(_readyMethod);
      return [
        for (final link in pending ?? const <String>[])
          ?LaunchAction.fromUri(Uri.tryParse(link)),
      ];
    } catch (e) {
      debugPrint('app intents: ready failed: $e');
      return const [];
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != _openMethod) {
      return;
    }
    final action = LaunchAction.fromUri(Uri.tryParse('${call.arguments}'));
    if (action != null) {
      _actions.add(action);
    }
  }

  void dispose() {
    if (_supported) {
      _channel.setMethodCallHandler(null);
    }
    _actions.close();
  }
}
