/// File intake that needs platform-specific plumbing. On the web this talks
/// to the browser directly (HTML drag events for drop targets, an
/// `<input type=file>` for the picker, Flutter's DragTarget never sees OS
/// files, and file_picker's web cancel detection races Firefox's dialog);
/// everywhere else drops are a no-op and picking goes through file_picker.
library;

export 'file_drop_stub.dart' if (dart.library.js_interop) 'file_drop_web.dart';
