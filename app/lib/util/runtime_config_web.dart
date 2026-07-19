import 'dart:js_interop';

/// The backend URL the server stamped into the page, or null when unset.
@JS('stickyNotesApiBase')
external JSString? get _apiBase;

String? runtimeApiBase() {
  final value = _apiBase?.toDart;
  if (value == null || value.isEmpty) return null;
  return value;
}
