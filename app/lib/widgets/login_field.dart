/// One input of the login form.
///
/// Everywhere but the web this is an ordinary [TextField] with `autofillHints`,
/// which is exactly what the OS password managers want. The web needs its own
/// implementation: Flutter's web engine does supply an autofill `<form>`, but
/// it only materializes once a field is focused and every input in it is sized
/// `0x0` and painted transparent. Browsers' built-in managers fill it anyway
/// (they go by the `autocomplete` attribute), while extensions such as
/// Bitwarden and 1Password skip fields they consider not viewable, so on the
/// web the fields are real, visible DOM inputs instead.
library;

export 'login_field_stub.dart'
    if (dart.library.js_interop) 'login_field_web.dart';
