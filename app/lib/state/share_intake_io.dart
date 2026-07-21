import 'dart:async';
import 'dart:io';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../models/dropped_file.dart';
import '../util/mime.dart';
import 'notes_store.dart';
import 'share_payload.dart';

/// Mobile intake for the OS share sheet: listens for content shared into the
/// app and creates a note for it (text/link → text note; media/files → an
/// attachment note). Silent + optimistic — reports through [showMessage] so the
/// caller can toast.
///
/// A payload can arrive before the user is signed in / the [NotesStore] exists
/// (cold start straight into the share), so payloads queue and replay once
/// [setStore] hands us a store.
class ShareIntake {
  ShareIntake({required this.showMessage});

  final void Function(String message) showMessage;

  NotesStore? _store;
  final List<SharePayload> _pending = [];
  StreamSubscription<List<SharedMediaFile>>? _sub;
  bool _started = false;
  bool _draining = false;

  void start() {
    if (_started) return;
    // The plugin only backs Android + iOS; skip elsewhere so desktop debug
    // runs don't hit MissingPluginException.
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _started = true;

    // Shares while the app is already running.
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _onMedia,
      onError: (_) {},
    );

    // A share that cold-started the app.
    ReceiveSharingIntent.instance.getInitialMedia().then((media) {
      _onMedia(media);
      // Don't re-deliver this initial payload on a later resume.
      ReceiveSharingIntent.instance.reset();
    });
  }

  void _onMedia(List<SharedMediaFile> media) {
    final payload = classifyShare(media);
    if (payload == null) return;
    _pending.add(payload);
    _drain();
  }

  /// Called by `main.dart` when the signed-in store appears or is torn down.
  void setStore(NotesStore? store) {
    _store = store;
    _drain();
  }

  Future<void> _drain() async {
    if (_draining) return;
    final store = _store;
    if (store == null) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty && _store != null) {
        final payload = _pending.removeAt(0);
        await _handle(_store!, payload);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _handle(NotesStore store, SharePayload payload) async {
    switch (payload) {
      case SharedTextPayload(:final text):
        final id = await store.createTextNote(text);
        if (id != null) showMessage('Created a note from shared text');
      case SharedFilesPayload(:final files):
        final dropped = <DroppedFile>[];
        for (final f in files) {
          try {
            final bytes = await File(f.path).readAsBytes();
            final name = _fileName(f.path);
            final mime = f.mimeType ?? mimeFromName(name);
            dropped.add(DroppedFile(name: name, mime: mime, bytes: bytes));
          } catch (_) {
            // Skip an unreadable item; the rest may still make it.
          }
        }
        if (dropped.isEmpty) return;
        final id = await store.createNoteWithFiles(dropped);
        if (id != null) {
          final noun = dropped.length == 1 ? 'file' : 'files';
          showMessage('Created a note from shared $noun');
        }
    }
  }

  String _fileName(String path) {
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    return name.isEmpty ? 'shared' : name;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
