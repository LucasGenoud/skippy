import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/saved_location.dart';
import '../../state/settings_store.dart';
import '../../util/location_geofences.dart';
import '../../util/snack.dart';
import '../form_dialog.dart';
import 'location_map_picker.dart';

class SavedLocationsSection extends StatelessWidget {
  const SavedLocationsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Save personal places such as Home or Work, then attach an '
            'arrival or departure reminder to any note. Coordinates are '
            'private to your account and are not shared with collaborators.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final location in settings.savedLocations)
          ListTile(
            key: ValueKey('saved-location-${location.id}'),
            leading: const Icon(Icons.place_outlined),
            title: Text(location.name),
            subtitle: Text(
              '${location.latitude.toStringAsFixed(5)}, '
              '${location.longitude.toStringAsFixed(5)} · '
              '${location.radiusMeters.round()} m radius',
            ),
            onTap: () => SavedLocationDialog.show(context, location),
            trailing: IconButton(
              tooltip: 'Delete ${location.name}',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => settings.removeSavedLocation(location.id),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('add-saved-location'),
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Add saved location'),
              onPressed: () => SavedLocationDialog.show(context, null),
            ),
          ),
        ),
        if (!LocationGeofences.supported)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Location reminders are monitored by the iOS or Android app.',
            ),
          ),
      ],
    );
  }
}

class SavedLocationDialog extends StatefulWidget {
  final SavedLocation? location;

  const SavedLocationDialog({super.key, this.location});

  static Future<void> show(BuildContext context, SavedLocation? location) =>
      showFormDialog<void>(
        context,
        builder: (_) => SavedLocationDialog(location: location),
      );

  @override
  State<SavedLocationDialog> createState() => _SavedLocationDialogState();
}

class _SavedLocationDialogState extends State<SavedLocationDialog> {
  /// Where a place with no coordinates yet starts: the middle of the map,
  /// zoomed out far enough that panning to your own part of the world is a
  /// couple of gestures. "Use current location" is the short way there.
  static const double _fallbackLatitude = 46.948;
  static const double _fallbackLongitude = 7.4474;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _latitude;
  late final TextEditingController _longitude;
  late final TextEditingController _radius;

  // What the map is showing. Deliberately the last values that *parsed*, not
  // whatever the fields currently hold: halfway through typing "46.9" the
  // latitude reads 46, and a map that jumps to the equator and back on every
  // keystroke is unusable.
  late double _mapLatitude;
  late double _mapLongitude;
  late double _mapRadius;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    final location = widget.location;
    _name = TextEditingController(text: location?.name ?? '');
    // A new place starts on the coordinates the map opens at, rather than
    // empty: the pin is then always the thing that gets saved, and moving it
    // is the whole edit. Nothing is saved until the dialog is submitted.
    _latitude = TextEditingController(
      text: (location?.latitude ?? _fallbackLatitude).toStringAsFixed(6),
    );
    _longitude = TextEditingController(
      text: (location?.longitude ?? _fallbackLongitude).toStringAsFixed(6),
    );
    _radius = TextEditingController(
      text: (location?.radiusMeters ?? 150).round().toString(),
    );
    _mapLatitude = location?.latitude ?? _fallbackLatitude;
    _mapLongitude = location?.longitude ?? _fallbackLongitude;
    _mapRadius = location?.radiusMeters ?? 150;
    _latitude.addListener(_onCoordinateTyped);
    _longitude.addListener(_onCoordinateTyped);
    _radius.addListener(_onCoordinateTyped);
  }

  @override
  void dispose() {
    _name.dispose();
    _latitude.dispose();
    _longitude.dispose();
    _radius.dispose();
    super.dispose();
  }

  /// The map follows the fields as they are typed, not only on save.
  void _onCoordinateTyped() {
    final latitude = _parsed(_latitude, -90, 90);
    final longitude = _parsed(_longitude, -180, 180);
    final radius = _parsed(_radius, 50, 5000);
    if (latitude == _mapLatitude &&
        longitude == _mapLongitude &&
        radius == _mapRadius) {
      return;
    }
    setState(() {
      _mapLatitude = latitude ?? _mapLatitude;
      _mapLongitude = longitude ?? _mapLongitude;
      _mapRadius = radius ?? _mapRadius;
    });
  }

  double? _parsed(TextEditingController controller, double min, double max) {
    final value = double.tryParse(controller.text.trim());
    if (value == null || value < min || value > max) return null;
    return value;
  }

  /// Panning the map is the same edit as typing coordinates, so it writes to
  /// the same fields rather than keeping a second copy of the truth.
  void _onMapMoved(({double latitude, double longitude}) point) {
    _latitude.text = point.latitude.toStringAsFixed(6);
    _longitude.text = point.longitude.toStringAsFixed(6);
  }

  String? _coordinateValidator(String? raw, double min, double max) {
    final value = double.tryParse(raw?.trim() ?? '');
    if (value == null || value < min || value > max) {
      return 'Enter a value from $min to $max';
    }
    return null;
  }

  Future<void> _useCurrentPosition() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final position = await LocationGeofences.instance.currentPosition();
      if (!mounted) return;
      if (position == null) {
        showAppSnack(
          'Location is unavailable. Check the system location permission.',
          icon: Icons.location_disabled_outlined,
          kind: SnackKind.warning,
        );
        return;
      }
      _latitude.text = position.latitude.toStringAsFixed(6);
      _longitude.text = position.longitude.toStringAsFixed(6);
    } catch (_) {
      if (mounted) {
        showAppSnack(
          'Could not determine the current location.',
          icon: Icons.location_disabled_outlined,
          kind: SnackKind.warning,
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final settings = context.read<SettingsStore>();
    final args = (
      name: _name.text.trim(),
      latitude: double.parse(_latitude.text.trim()),
      longitude: double.parse(_longitude.text.trim()),
      radius: double.parse(_radius.text.trim()),
    );
    final existing = widget.location;
    if (existing == null) {
      settings.addSavedLocation(
        name: args.name,
        latitude: args.latitude,
        longitude: args.longitude,
        radiusMeters: args.radius,
      );
    } else {
      settings.updateSavedLocation(
        existing.id,
        name: args.name,
        latitude: args.latitude,
        longitude: args.longitude,
        radiusMeters: args.radius,
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: Text(
      widget.location == null ? 'Add saved location' : 'Edit location',
    ),
    content: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _name,
            autofocus: widget.location == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Home, Work, School…',
            ),
            validator: (value) =>
                value == null || value.trim().isEmpty ? 'Enter a name' : null,
          ),
          const SizedBox(height: 12),
          LocationMapPicker(
            latitude: _mapLatitude,
            longitude: _mapLongitude,
            radiusMeters: _mapRadius,
            onMoved: _onMapMoved,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Drag the map to put the pin on the place. The circle is '
                  'how close you have to be.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (LocationGeofences.supported) ...[
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const ValueKey('use-current-location'),
                  tooltip: 'Use current location',
                  onPressed: _locating ? null : _useCurrentPosition,
                  icon: _locating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _latitude,
                  decoration: const InputDecoration(labelText: 'Latitude'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  validator: (value) => _coordinateValidator(value, -90, 90),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _longitude,
                  decoration: const InputDecoration(labelText: 'Longitude'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  validator: (value) => _coordinateValidator(value, -180, 180),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _radius,
            decoration: const InputDecoration(
              labelText: 'Radius in metres',
              helperText: '100–150 m is usually reliable outdoors',
            ),
            keyboardType: TextInputType.number,
            validator: (raw) {
              final value = double.tryParse(raw?.trim() ?? '');
              if (value == null || value < 50 || value > 5000) {
                return 'Enter a radius from 50 to 5000 metres';
              }
              return null;
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
