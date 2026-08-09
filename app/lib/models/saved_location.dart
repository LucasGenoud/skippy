/// A named place the user can reuse for location-based note reminders.
///
/// Saved places and the reminders that reference them live in the user's
/// opaque settings document. They are deliberately personal rather than note
/// fields: collaborators must not learn somebody else's home or work address.
class SavedLocation {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double radiusMeters;

  const SavedLocation({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusMeters = 150,
  });

  bool get isValid =>
      id.isNotEmpty &&
      name.trim().isNotEmpty &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      radiusMeters >= 50 &&
      radiusMeters <= 5000;

  SavedLocation copyWith({
    String? name,
    double? latitude,
    double? longitude,
    double? radiusMeters,
  }) => SavedLocation(
    id: id,
    name: name ?? this.name,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    radiusMeters: radiusMeters ?? this.radiusMeters,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'radius_meters': radiusMeters,
  };

  static SavedLocation? fromJson(Map<String, dynamic> json) {
    final location = SavedLocation(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? double.nan,
      longitude: (json['longitude'] as num?)?.toDouble() ?? double.nan,
      radiusMeters: (json['radius_meters'] as num?)?.toDouble() ?? 150,
    );
    return location.isValid ? location : null;
  }
}

enum LocationReminderTrigger {
  arrive('arrive', 'When I arrive'),
  leave('leave', 'When I leave');

  final String wire;
  final String label;
  const LocationReminderTrigger(this.wire, this.label);

  static LocationReminderTrigger? fromWire(String? value) {
    for (final trigger in values) {
      if (trigger.wire == value) return trigger;
    }
    return null;
  }
}

/// One personal, one-shot location reminder attached to a note.
class LocationReminder {
  final String noteId;
  final String locationId;
  final LocationReminderTrigger trigger;

  const LocationReminder({
    required this.noteId,
    required this.locationId,
    required this.trigger,
  });

  Map<String, dynamic> toJson() => {
    'note_id': noteId,
    'location_id': locationId,
    'trigger': trigger.wire,
  };

  static LocationReminder? fromJson(Map<String, dynamic> json) {
    final noteId = (json['note_id'] as String?)?.trim() ?? '';
    final locationId = (json['location_id'] as String?)?.trim() ?? '';
    final trigger = LocationReminderTrigger.fromWire(
      json['trigger'] as String?,
    );
    if (noteId.isEmpty || locationId.isEmpty || trigger == null) return null;
    return LocationReminder(
      noteId: noteId,
      locationId: locationId,
      trigger: trigger,
    );
  }
}
