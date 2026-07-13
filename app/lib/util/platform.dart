import 'package:flutter/foundation.dart';

/// True when the primary pointer is a finger (Android/iOS/Fuchsia).
///
/// Touch UIs keep drag affordances always visible and start grid drags on
/// long-press so scrolling wins the gesture arena; mouse UIs get
/// hover-revealed controls and instant drag.
bool get isTouchPrimaryPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia =>
    true,
  _ => false,
};
