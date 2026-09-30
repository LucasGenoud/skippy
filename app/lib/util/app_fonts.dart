import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The typefaces the app can be set in. [system] is each platform's own UI
/// font (Roboto, San Francisco, Segoe UI) and needs nothing loaded.
///
/// The others ship as plain assets in `assets/fonts/<family>/`, deliberately
/// not declared under `fonts:` in pubspec: the web engine downloads every
/// declared font before its first frame, and nobody should wait on 2.7 MB of
/// typefaces they never picked. [AppFontLoader] reads a family on first use.
enum AppFont {
  system(label: 'System default'),
  inter(label: 'Inter', family: 'Inter'),
  nunito(label: 'Nunito', family: 'Nunito'),
  lora(label: 'Lora', family: 'Lora'),
  jetBrainsMono(label: 'JetBrains Mono', family: 'JetBrainsMono');

  final String label;
  final String? family;
  const AppFont({required this.label, this.family});
}

/// Registers bundled families with the engine on demand and says when each
/// one can be drawn.
///
/// One instance for the process, because the engine's font registry is
/// process-wide too. The theme asks [resolve] rather than naming a family
/// outright: text laid out before its family is registered falls back to the
/// platform font, and measurements taken then (card heights, for one) would
/// outlive the swap. Holding the theme on the platform font until the family
/// is ready, then notifying, rebuilds everything in the new face at once.
class AppFontLoader extends ChangeNotifier {
  AppFontLoader._();

  static final AppFontLoader instance = AppFontLoader._();

  /// One file per weight the interface draws in. The engine reads each file's
  /// weight from the file itself, so they share one family name.
  static const _weights = ['Regular', 'Medium', 'SemiBold', 'Bold'];

  final Set<AppFont> _ready = {};
  final Map<AppFont, Future<void>> _loading = {};

  /// The family to draw [font] in right now: its own once registered, null
  /// (the platform font) until then. Starts loading it if nothing has.
  String? resolve(AppFont font) {
    if (_ready.contains(font)) {
      return font.family;
    }

    unawaited(load(font));
    return null;
  }

  /// Registers [font]'s files once; later calls share the first attempt.
  Future<void> load(AppFont font) {
    final family = font.family;
    if (family == null) {
      return Future.value();
    }

    return _loading[font] ??= _register(font, family);
  }

  Future<void> _register(AppFont font, String family) async {
    final loader = FontLoader(family);
    for (final weight in _weights) {
      loader.addFont(
        rootBundle.load('assets/fonts/$family/$family-$weight.ttf'),
      );
    }

    // An unreadable file leaves the platform font in place rather than
    // failing the frame that asked.
    try {
      await loader.load();
    } catch (error) {
      debugPrint('Could not load font $family: $error');
      return;
    }

    _ready.add(font);
    notifyListeners();
  }
}
