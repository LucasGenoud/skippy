import 'notes_store.dart';

/// No-op stand-in used on web (and anywhere without `dart:io`). Keeps the same
/// surface as the real mobile intake so `main.dart` can wire it unconditionally.
class ShareIntake {
  ShareIntake({required void Function(String message) showMessage});

  void start() {}
  void setStore(NotesStore? store) {}
  void dispose() {}
}
