import 'dart:convert';

const int _formatVersion = 1;

/// How a tracker reads its log.
enum TrackerStyle {
  /// A tally: tap to add one, and see the total and today's share of it.
  count('Count'),

  /// A habit: tick off days on a calendar and keep a streak going.
  habit('Habit');

  final String label;

  const TrackerStyle(this.label);
}

String _days(int n) => n == 1 ? '1 day' : '$n days';

/// The `yyyy-mm-dd` key a local calendar day is logged under.
String trackerDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// A counter or habit note, encoded into its `content`.
///
/// Both styles keep the same day-by-day log, `{"2026-11-26": 3}`, so turning
/// a tally into a habit keeps every day it counted. Days with nothing logged
/// are left out. The wire shape is `{"v":1,"style":"count","log":{...}}`.
class Tracker {
  final TrackerStyle style;
  final Map<String, int> log;

  const Tracker({this.style = TrackerStyle.count, this.log = const {}});

  static const empty = Tracker();

  /// Everything ever counted.
  int get total => log.values.fold(0, (sum, n) => sum + n);

  int on(DateTime day) => log[trackerDay(day)] ?? 0;

  /// [by] more (or fewer) on [day], never below zero.
  Tracker add(DateTime day, int by) {
    final key = trackerDay(day);
    final next = (log[key] ?? 0) + by;
    final updated = {...log}..remove(key);
    if (next > 0) {
      updated[key] = next;
    }
    return Tracker(style: style, log: updated);
  }

  /// Marks [day] done, or undone if it already was.
  Tracker toggle(DateTime day) => add(day, on(day) > 0 ? -on(day) : 1);

  Tracker withStyle(TrackerStyle style) => Tracker(style: style, log: log);

  /// Days in a row with something logged, ending today. A streak still
  /// counts until today is over, so it runs from yesterday when today is
  /// not done yet.
  int streak(DateTime today) {
    var day = DateTime(today.year, today.month, today.day);
    if (on(day) == 0) {
      day = DateTime(day.year, day.month, day.day - 1);
    }
    var length = 0;
    while (on(day) > 0) {
      length++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return length;
  }

  /// Days with something logged in [day]'s month.
  int daysInMonth(DateTime day) {
    final prefix = trackerDay(day).substring(0, 8);
    return log.keys.where((key) => key.startsWith(prefix)).length;
  }

  /// One line saying where the tracker stands, for exports and copies.
  String summary(DateTime today) => switch (style) {
    TrackerStyle.count => '$total in all, ${on(today)} today',
    TrackerStyle.habit =>
      '${_days(streak(today))} streak, '
          '${_days(daysInMonth(today))} this month',
  };

  /// The note content for this tracker. Empty for a fresh count, so an
  /// untouched tracker is an empty note and is discarded like one.
  String encode() {
    if (log.isEmpty && style == TrackerStyle.count) {
      return '';
    }
    return jsonEncode({'v': _formatVersion, 'style': style.name, 'log': log});
  }

  /// Reads note content back. Anything unreadable is an empty tracker rather
  /// than an error, since content is written by clients.
  static Tracker parse(String content) {
    if (content.trim().isEmpty) {
      return empty;
    }
    try {
      final json = jsonDecode(content);
      if (json is! Map) {
        return empty;
      }
      final rawLog = json['log'];
      return Tracker(
        style:
            TrackerStyle.values.asNameMap()[json['style']] ??
            TrackerStyle.count,
        log: {
          if (rawLog is Map)
            for (final MapEntry(:key, :value) in rawLog.entries)
              if (key is String && value is int && value > 0) key: value,
        },
      );
    } on FormatException {
      return empty;
    }
  }
}
