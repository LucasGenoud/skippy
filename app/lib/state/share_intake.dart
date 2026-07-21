// Receives content shared into the app from the OS share sheet and turns it
// into a note. Mobile-only (Android intents / iOS Share Extension via the
// receive_sharing_intent plugin); the web build gets an inert stub so nothing
// pulls in `dart:io` or the plugin.
export 'share_intake_stub.dart'
    if (dart.library.io) 'share_intake_io.dart';
