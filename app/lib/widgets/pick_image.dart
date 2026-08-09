import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/dropped_file.dart';
import '../util/mime.dart';
import 'form_dialog.dart';

/// Whether this device can hand back a freshly taken picture. Only the mobile
/// platforms carry a real camera intent: the web picker's camera support
/// depends on the browser and desktop has no implementation at all, so those
/// keep going straight to the file picker rather than offering a shutter that
/// might not open.
bool get canTakePhoto =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Picks an image for a note, asking the camera or the photo library.
///
/// On a phone the choice comes first, as a sheet, because the two are equally
/// likely ways to add a picture and the camera is the one a desktop-shaped
/// "browse files" flow can't reach. Everywhere else there is nothing to
/// choose, so the library opens directly. Null when the user backs out of
/// either step.
Future<DroppedFile?> pickNoteImage(BuildContext context) async {
  final source = canTakePhoto
      ? await chooseImageSource(context)
      : ImageSource.gallery;
  if (source == null) return null;
  final picked = await ImagePicker().pickImage(source: source);
  if (picked == null) return null;
  final bytes = await picked.readAsBytes();
  var mime = picked.mimeType ?? mimeFromName(picked.name);
  if (source != ImageSource.camera) {
    return DroppedFile(name: picked.name, mime: mime, bytes: bytes);
  }
  // A capture arrives as a temporary file whose name is the plugin's
  // bookkeeping (`image_picker1234.jpg`), so it gets a stamped one like a
  // pasted screenshot does. Cameras shoot JPEG; the fallback only matters if
  // the temp file came through without a usable extension.
  if (!mime.startsWith('image/')) mime = 'image/jpeg';
  return DroppedFile(name: capturedFileName(mime), mime: mime, bytes: bytes);
}

/// The camera-or-library sheet [pickNoteImage] shows on mobile. Null when it
/// is dismissed without a choice.
Future<ImageSource?> chooseImageSource(BuildContext context) =>
    showAdaptiveSelectionSurface<ImageSource>(
      context,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? 'Choose from library'
                    : 'Choose from gallery',
              ),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
