import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/notify_channels.dart';
import '../theme.dart';

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

/// How tightly the note grid packs cards. Each preset drives the auto-column
/// layout in the home grid: [targetWidth] is the ideal card width the layout
/// aims for, [maxColumns] caps how many fit, and [maxGridWidth] caps how wide
/// the whole grid may grow (so it can spread across a large desktop display, or
/// stay comfortably narrow). Comfortable reproduces the app's original layout,
/// so upgrading users see no change until they pick another preset.
enum GridDensity {
  compact(
    label: 'Compact',
    blurb: 'More, smaller cards — fills wide screens',
    targetWidth: 200,
    maxColumns: 8,
    maxGridWidth: 2400,
  ),
  comfortable(
    label: 'Comfortable',
    blurb: 'The default balance',
    targetWidth: 250,
    maxColumns: 5,
    maxGridWidth: 1400,
  ),
  spacious(
    label: 'Spacious',
    blurb: 'Fewer, larger cards',
    targetWidth: 320,
    maxColumns: 4,
    maxGridWidth: 1600,
  );

  final String label;
  final String blurb;
  final double targetWidth;
  final int maxColumns;
  final double maxGridWidth;
  const GridDensity({
    required this.label,
    required this.blurb,
    required this.targetWidth,
    required this.maxColumns,
    required this.maxGridWidth,
  });
}

/// Per-user preferences, synced to the server as an opaque JSON document so
/// they follow the user across devices. All reads are safe against missing
/// or malformed fields (unknown values fall back to defaults).
class SettingsStore extends ChangeNotifier {
  final Api api;

  ThemeMode themeMode = ThemeMode.system;
  Color accentColor = kDefaultAccent;
  AppDateFormat dateFormat = AppDateFormat.monthFirst;
  bool use24hTime = false;
  bool defaultListMode = false;
  GridDensity gridDensity = GridDensity.comfortable;
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

  // Whether the in-search "rank by meaning" (✨) toggle is on. Unlike the
  // feature toggle above this is the user's live search-mode preference, and
  // it's persisted so it survives closing the app. Defaults off (keyword
  // search) to match the plain-search-first behavior.
  bool semanticRanking = false;

  bool get semanticSearchAvailable =>
      semanticSearchCapable && semanticSearchEnabled;
  bool get audioNotesAvailable =>
      audioTranscriptionCapable && audioNotesEnabled;

  // LLM integration (OpenAI-compatible endpoint; Ollama works via its /v1
  // API). Unlike the features above there is no server capability: each user
  // brings their own endpoint/key/model, and the backend reads these same
  // llm_* keys out of the settings document when labeling or chatting.
  String llmBaseUrl = '';
  String llmApiKey = '';
  String llmModel = '';
  bool llmLabelingEnabled = true;
  bool llmChatEnabled = true;

  // Settings keys the self-hoster pinned via server env vars (backend
  // `config.rs`). A present key is locked in the UI and its value is
  // authoritative; secret keys carry no value. Fetched from
  // /api/managed-settings, not persisted. See [_applyManaged].
  Map<String, ManagedSetting> managed = {};

  /// Is this settings-document key server-managed (and thus locked)?
  bool isManaged(String key) => managed.containsKey(key);

  bool get llmConfigured => llmBaseUrl.isNotEmpty && llmModel.isNotEmpty;
  bool get autoLabelingAvailable => llmConfigured && llmLabelingEnabled;
  // Chat retrieval runs on the server's embedder, so it additionally needs
  // the semantic-search capability.
  bool get notesChatAvailable =>
      llmConfigured && llmChatEnabled && semanticSearchCapable;

  // Reminder notifications (ntfy, Telegram, …). Like the LLM config there is
  // no server capability: the channels in [kNotifyChannels] describe which
  // settings keys each one needs, the backend's connectors read those same
  // keys when a reminder comes due, and this map holds their values.
  Map<String, String> notifyValues = {};
  bool reminderNotificationsEnabled = true;

  bool get notifyConfigured =>
      kNotifyChannels.any((c) => c.configuredIn(notifyValues));

  /// Display names of the channels that are fully configured.
  List<String> get configuredNotifyChannels => [
    for (final channel in kNotifyChannels)
      if (channel.configuredIn(notifyValues)) channel.label,
  ];

  Timer? _saveDebounce;
  bool _savePending = false;
  int _customCounter = 0;

  SettingsStore({required this.api});

  /// Everything listeners can observe, serialized. [load] uses it to skip
  /// the notification when a refetch changed nothing: load() runs after
  /// every WS change nudge — including the echo of our own edits — and an
  /// unconditional notify would rebuild MaterialApp (fresh themes) and
  /// every note card each time.
  String _fingerprint() => jsonEncode({
    'doc': toJson(),
    'caps': [semanticSearchCapable, audioTranscriptionCapable],
    'managed': {
      for (final e in managed.entries) e.key: [e.value.secret, e.value.value],
    },
  });

  Future<void> load() async {
    final before = loaded ? _fingerprint() : null;
    // Server capabilities are independent of the (debounced) settings save, so
    // refresh them even while a local edit is still pending.
    try {
      final caps = await api.fetchCapabilities();
      semanticSearchCapable = caps.semanticSearch;
      audioTranscriptionCapable = caps.audioTranscription;
    } catch (_) {
      // Unreachable: leave capabilities as they were (default off).
    }
    // Server-managed overrides are independent of the pending local save too.
    try {
      managed = await api.fetchManagedSettings();
    } catch (_) {
      // Unreachable: leave as-is (default: nothing managed).
    }
    // Never clobber local edits that haven't reached the server yet.
    if (!_savePending) {
      try {
        _applyJson(await api.fetchSettings());
      } catch (_) {
        // Offline: defaults (or last applied values) stay in effect.
      }
    }
    // Managed values win over whatever the user's document carried.
    _applyManaged();
    loaded = true;
    if (before == null || _fingerprint() != before) notifyListeners();
  }

  /// Overlay the server-managed values onto the local fields, so the UI shows
  /// (and the store reports as "configured") what the server will actually use.
  /// Secret keys are blanked — the server never sends their value, and the
  /// client must never hold it.
  void _applyManaged() {
    String? text(String key) {
      final m = managed[key];
      if (m == null) return null;
      return m.secret ? '' : (m.value as String? ?? '');
    }

    bool? flag(String key) {
      final m = managed[key];
      if (m == null || m.value is! bool) return null;
      return m.value as bool;
    }

    llmBaseUrl = text('llm_base_url') ?? llmBaseUrl;
    llmApiKey = text('llm_api_key') ?? llmApiKey;
    llmModel = text('llm_model') ?? llmModel;
    llmLabelingEnabled = flag('llm_labeling') ?? llmLabelingEnabled;
    llmChatEnabled = flag('llm_chat') ?? llmChatEnabled;
  }

  void _applyJson(Map<String, dynamic> json) {
    themeMode = switch (json['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    accentColor =
        PaletteEntry.hexToColor(json['accent'] as String?) ?? kDefaultAccent;
    dateFormat =
        AppDateFormat.values.asNameMap()[json['date_format']] ??
        AppDateFormat.monthFirst;
    use24hTime = json['time_format'] == '24h';
    defaultListMode = json['default_view'] == 'list';
    gridDensity =
        GridDensity.values.asNameMap()[json['grid_density']] ??
        GridDensity.comfortable;
    // Feature toggles default ON when absent (they only take effect when the
    // server also advertises the capability).
    semanticSearchEnabled = json['semantic_search'] != false;
    semanticRanking = json['semantic_ranking'] == true;
    audioNotesEnabled = json['audio_notes'] != false;
    llmBaseUrl = ((json['llm_base_url'] as String?) ?? '').trim();
    llmApiKey = ((json['llm_api_key'] as String?) ?? '').trim();
    llmModel = ((json['llm_model'] as String?) ?? '').trim();
    llmLabelingEnabled = json['llm_labeling'] != false;
    llmChatEnabled = json['llm_chat'] != false;
    notifyValues = {
      for (final key in kNotifyFieldKeys)
        key: ((json[key] as String?) ?? '').trim(),
    };
    reminderNotificationsEnabled = json['reminder_notifications'] != false;
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
    'accent': PaletteEntry.colorToHex(accentColor),
    'date_format': dateFormat.name,
    'time_format': use24hTime ? '24h' : '12h',
    'default_view': defaultListMode ? 'list' : 'grid',
    'grid_density': gridDensity.name,
    'semantic_search': semanticSearchEnabled,
    'semantic_ranking': semanticRanking,
    'audio_notes': audioNotesEnabled,
    'llm_base_url': llmBaseUrl,
    'llm_api_key': llmApiKey,
    'llm_model': llmModel,
    'llm_labeling': llmLabelingEnabled,
    'llm_chat': llmChatEnabled,
    // toJson rebuilds the whole settings document, so every notify key must
    // appear here or a save from this device would erase it.
    for (final key in kNotifyFieldKeys) key: notifyValues[key] ?? '',
    'reminder_notifications': reminderNotificationsEnabled,
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
  void setAccentColor(Color color) => _mutate(() => accentColor = color);

  /// Cycle light/dark from the app-bar button, given the effective brightness.
  void toggleTheme(Brightness current) => _mutate(() {
    themeMode = current == Brightness.light ? ThemeMode.dark : ThemeMode.light;
  });

  void setDateFormat(AppDateFormat format) =>
      _mutate(() => dateFormat = format);
  void setUse24hTime(bool value) => _mutate(() => use24hTime = value);
  void setDefaultListMode(bool value) => _mutate(() => defaultListMode = value);
  void setGridDensity(GridDensity value) =>
      _mutate(() => gridDensity = value);
  void setSemanticSearchEnabled(bool value) =>
      _mutate(() => semanticSearchEnabled = value);
  void setSemanticRanking(bool value) => _mutate(() => semanticRanking = value);
  void setAudioNotesEnabled(bool value) =>
      _mutate(() => audioNotesEnabled = value);

  void setLlmConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) => _mutate(() {
    llmBaseUrl = baseUrl.trim();
    llmApiKey = apiKey.trim();
    llmModel = model.trim();
  });
  void setLlmLabelingEnabled(bool value) =>
      _mutate(() => llmLabelingEnabled = value);
  void setLlmChatEnabled(bool value) => _mutate(() => llmChatEnabled = value);

  void setNotifyValues(Map<String, String> values) => _mutate(() {
    notifyValues = {
      for (final key in kNotifyFieldKeys) key: (values[key] ?? '').trim(),
    };
  });
  void setReminderNotificationsEnabled(bool value) =>
      _mutate(() => reminderNotificationsEnabled = value);

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
