import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';

/// One entry in the user's note-color palette.
class PaletteEntry {
  final String key;
  final String name;
  final Color light;
  final Color dark;

  const PaletteEntry({
    required this.key,
    required this.name,
    required this.light,
    required this.dark,
  });

  PaletteEntry copyWith({String? name, Color? light, Color? dark}) =>
      PaletteEntry(
        key: key,
        name: name ?? this.name,
        light: light ?? this.light,
        dark: dark ?? this.dark,
      );

  static String colorToHex(Color c) {
    String channel(double v) =>
        (v * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${channel(c.r)}${channel(c.g)}${channel(c.b)}'.toUpperCase();
  }

  static Color? hexToColor(String? hex) {
    if (hex == null) return null;
    final cleaned = hex.replaceFirst('#', '').trim();
    if (cleaned.length != 6) return null;
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'light': colorToHex(light),
    'dark': colorToHex(dark),
  };

  static PaletteEntry? fromJson(Map<String, dynamic> json) {
    final key = json['key'] as String?;
    final light = hexToColor(json['light'] as String?);
    final dark = hexToColor(json['dark'] as String?);
    if (key == null || key.isEmpty || light == null || dark == null) {
      return null;
    }
    return PaletteEntry(
      key: key,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : key,
      light: light,
      dark: dark,
    );
  }
}

/// Keep's classic 8 colors — the palette users start from and can reset to.
const List<PaletteEntry> kDefaultPalette = [
  PaletteEntry(
    key: 'red',
    name: 'Red',
    light: Color(0xFFF28B82),
    dark: Color(0xFF5C2B29),
  ),
  PaletteEntry(
    key: 'orange',
    name: 'Orange',
    light: Color(0xFFFBBC04),
    dark: Color(0xFF614A19),
  ),
  PaletteEntry(
    key: 'yellow',
    name: 'Yellow',
    light: Color(0xFFFFF475),
    dark: Color(0xFF635D19),
  ),
  PaletteEntry(
    key: 'green',
    name: 'Green',
    light: Color(0xFFCCFF90),
    dark: Color(0xFF345920),
  ),
  PaletteEntry(
    key: 'teal',
    name: 'Teal',
    light: Color(0xFFA7FFEB),
    dark: Color(0xFF16504B),
  ),
  PaletteEntry(
    key: 'blue',
    name: 'Blue',
    light: Color(0xFFAECBFA),
    dark: Color(0xFF2D555E),
  ),
  PaletteEntry(
    key: 'gray',
    name: 'Gray',
    light: Color(0xFFE8EAED),
    dark: Color(0xFF3C3F43),
  ),
];

enum AppDateFormat {
  monthFirst('Jul 15, 2026'),
  dayFirst('15 Jul 2026'),
  numericUS('07/15/2026'),
  numericEU('15.07.2026'),
  iso('2026-07-15');

  final String example;
  const AppDateFormat(this.example);
}

/// Per-user preferences, synced to the server as an opaque JSON document so
/// they follow the user across devices. All reads are safe against missing
/// or malformed fields (unknown values fall back to defaults).
class SettingsStore extends ChangeNotifier {
  final Api api;

  ThemeMode themeMode = ThemeMode.system;
  AppDateFormat dateFormat = AppDateFormat.monthFirst;
  bool use24hTime = false;
  bool defaultListMode = false;
  List<PaletteEntry> palette = List.of(kDefaultPalette);
  bool loaded = false;

  // Optional features. Each has a server *capability* (is the backing service
  // running?) fetched from /api/capabilities and NOT persisted, plus a synced
  // user *toggle*. A feature is available only when both are true — so it
  // hides automatically when the service is down, and can be turned off by the
  // user even when it's up.
  bool semanticSearchCapable = false;
  bool audioTranscriptionCapable = false;
  bool semanticSearchEnabled = true;
  bool audioNotesEnabled = true;

  bool get semanticSearchAvailable =>
      semanticSearchCapable && semanticSearchEnabled;
  bool get audioNotesAvailable =>
      audioTranscriptionCapable && audioNotesEnabled;

  Timer? _saveDebounce;
  bool _savePending = false;
  int _customCounter = 0;

  SettingsStore({required this.api});

  Future<void> load() async {
    // Server capabilities are independent of the (debounced) settings save, so
    // refresh them even while a local edit is still pending.
    try {
      final caps = await api.fetchCapabilities();
      semanticSearchCapable = caps.semanticSearch;
      audioTranscriptionCapable = caps.audioTranscription;
    } catch (_) {
      // Unreachable: leave capabilities as they were (default off).
    }
    // Never clobber local edits that haven't reached the server yet.
    if (!_savePending) {
      try {
        _applyJson(await api.fetchSettings());
      } catch (_) {
        // Offline: defaults (or last applied values) stay in effect.
      }
    }
    loaded = true;
    notifyListeners();
  }

  void _applyJson(Map<String, dynamic> json) {
    themeMode = switch (json['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    dateFormat =
        AppDateFormat.values.asNameMap()[json['date_format']] ??
        AppDateFormat.monthFirst;
    use24hTime = json['time_format'] == '24h';
    defaultListMode = json['default_view'] == 'list';
    // Feature toggles default ON when absent (they only take effect when the
    // server also advertises the capability).
    semanticSearchEnabled = json['semantic_search'] != false;
    audioNotesEnabled = json['audio_notes'] != false;
    final rawPalette = json['palette'];
    if (rawPalette is List) {
      final parsed = [
        for (final entry in rawPalette)
          if (entry is Map<String, dynamic>)
            if (PaletteEntry.fromJson(entry) case final PaletteEntry e) e,
      ];
      if (parsed.isNotEmpty) palette = parsed;
    }
  }

  Map<String, dynamic> toJson() => {
    'theme': switch (themeMode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    },
    'date_format': dateFormat.name,
    'time_format': use24hTime ? '24h' : '12h',
    'default_view': defaultListMode ? 'list' : 'grid',
    'semantic_search': semanticSearchEnabled,
    'audio_notes': audioNotesEnabled,
    'palette': [for (final entry in palette) entry.toJson()],
  };

  void _mutate(VoidCallback change) {
    change();
    notifyListeners();
    _savePending = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () async {
      try {
        await api.putSettings(toJson());
        _savePending = false;
      } catch (_) {
        // Retry on the next mutation or app start; local values still apply.
      }
    });
  }

  void setThemeMode(ThemeMode mode) => _mutate(() => themeMode = mode);

  /// Cycle light/dark from the app-bar button, given the effective brightness.
  void toggleTheme(Brightness current) => _mutate(() {
    themeMode = current == Brightness.light ? ThemeMode.dark : ThemeMode.light;
  });

  void setDateFormat(AppDateFormat format) =>
      _mutate(() => dateFormat = format);
  void setUse24hTime(bool value) => _mutate(() => use24hTime = value);
  void setDefaultListMode(bool value) => _mutate(() => defaultListMode = value);
  void setSemanticSearchEnabled(bool value) =>
      _mutate(() => semanticSearchEnabled = value);
  void setAudioNotesEnabled(bool value) =>
      _mutate(() => audioNotesEnabled = value);

  // -- palette ---------------------------------------------------------------

  void addPaletteColor(String name, Color light, Color dark) => _mutate(() {
    final key =
        'custom-${DateTime.now().millisecondsSinceEpoch}-${_customCounter++}';
    palette = [
      ...palette,
      PaletteEntry(
        key: key,
        name: name.trim().isEmpty ? 'Custom' : name.trim(),
        light: light,
        dark: dark,
      ),
    ];
  });

  void updatePaletteColor(
    String key, {
    String? name,
    Color? light,
    Color? dark,
  }) => _mutate(() {
    palette = [
      for (final entry in palette)
        entry.key == key
            ? entry.copyWith(name: name, light: light, dark: dark)
            : entry,
    ];
  });

  void removePaletteColor(String key) => _mutate(() {
    palette = palette.where((e) => e.key != key).toList();
  });

  void resetPalette() => _mutate(() => palette = List.of(kDefaultPalette));

  /// Resolved fill for a note color key; null means plain surface (default).
  /// Notes keep working if their color was removed from the palette: legacy
  /// default keys resolve from [kDefaultPalette], unknown keys fall back to
  /// the plain surface.
  Color? resolveColor(String key, Brightness brightness) {
    if (key == 'default') return null;
    for (final entry in palette) {
      if (entry.key == key) {
        return brightness == Brightness.light ? entry.light : entry.dark;
      }
    }
    for (final entry in kDefaultPalette) {
      if (entry.key == key) {
        return brightness == Brightness.light ? entry.light : entry.dark;
      }
    }
    return null;
  }

  // -- date & time formatting -------------------------------------------------

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String formatClock(DateTime t) {
    final m = t.minute.toString().padLeft(2, '0');
    if (use24hTime) return '${t.hour.toString().padLeft(2, '0')}:$m';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  String formatDate(DateTime d, {bool withYear = true}) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return switch (dateFormat) {
      AppDateFormat.monthFirst =>
        '${_months[d.month - 1]} ${d.day}${withYear ? ', ${d.year}' : ''}',
      AppDateFormat.dayFirst =>
        '${d.day} ${_months[d.month - 1]}${withYear ? ' ${d.year}' : ''}',
      AppDateFormat.numericUS => '$mm/$dd/${d.year}',
      AppDateFormat.numericEU => '$dd.$mm.${d.year}',
      AppDateFormat.iso => '${d.year}-$mm-$dd',
    };
  }

  /// "Today 9:00 AM", "Tomorrow 18:30", "Jul 24, 2026, 9:00 AM" — chips.
  String reminderLabel(DateTime t) {
    final now = DateTime.now();
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final delta = day.difference(today).inDays;
    if (delta == 0) return 'Today ${formatClock(t)}';
    if (delta == 1) return 'Tomorrow ${formatClock(t)}';
    if (delta == -1) return 'Yesterday ${formatClock(t)}';
    return '${formatDate(t, withYear: t.year != now.year)}, ${formatClock(t)}';
  }

  /// Relative stamp for "Edited …".
  String editedLabel(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24 && now.day == t.day) return formatClock(t);
    return formatDate(t, withYear: t.year != now.year);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
