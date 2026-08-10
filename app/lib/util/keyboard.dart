import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Puts the soft keyboard away, and makes it stay away.
///
/// Unfocusing is the half every Flutter app does, and on its own it is enough
/// while the app owns the screen. It is not enough around a native picker (the
/// photo library, the camera, a document browser): that runs in its own
/// platform UI, and on the way back the system restores the window state it
/// suspended, keyboard included, without Flutter's focus tree necessarily
/// holding an editable to unfocus. Telling the engine to hide the text input
/// covers that case and is a no-op when the keyboard is already down.
void dismissKeyboard() {
  FocusManager.instance.primaryFocus?.unfocus();
  SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
}
