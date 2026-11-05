/// ADR-090: minimal display data; this projection never performs a school query.
library;

import '../../session/session_controller.dart' show ScriptCachedData;

DateTime? _date(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }
  final date = DateTime.tryParse('${value}T00:00:00Z');
  return date != null && date.toIso8601String().startsWith(value) ? date : null;
}

String _day(DateTime date) => date.toIso8601String().substring(0, 10);
String _short(Object? value, int limit) {
  if (value is! String) return '';
  final text = value.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
  // Native limits use UTF-16 units. Walk code points so an astral character
  // either fits in full or is omitted, never leaving half a surrogate pair.
  final result = StringBuffer();
  var units = 0;
  for (final rune in text.runes) {
    final width = rune > 0xffff ? 2 : 1;
    if (units + width > limit) break;
    result.writeCharCode(rune);
    units += width;
  }
  return result.toString();
}

Map<String, Object?>? scheduleWidgetSnapshot(
  ScriptCachedData cached, {
  required String schoolDate,
  required String schemaVersion,
}) {
  final today = _date(schoolDate);
  final raw = cached.data;
  if (today == null || raw is! Map || schemaVersion != '1.3') return null;
  final zone = raw['timeZone'];
  if (zone is! String || zone.isEmpty || zone.length > 80) return null;
  final known = <String, List<Map<String, Object?>>>{};
  final dateOwners = <String, int>{};
  final conflicts = <String>{};
  void addWeek(Map week, {bool explicitEmpty = false}) {
    final weekNumber = week['week'];
    final start = _date(week['teachingWeekStart']);
    final end = _date(week['teachingWeekEnd']);
    final days = week['days'];
    if (weekNumber is! int ||
        weekNumber < 1 ||
        start == null ||
        end == null ||
        end.difference(start).inDays != 6 ||
        days is! List) {
      return;
    }
    for (var i = 0; i < 7; i++) {
      final date = _day(start.add(Duration(days: i)));
      final owner = dateOwners[date];
      if (owner != null && owner != weekNumber) conflicts.add(date);
      dateOwners[date] = weekNumber;
    }
    if (explicitEmpty && days.isEmpty) {
      for (var i = 0; i < 7; i++) {
        known[_day(start.add(Duration(days: i)))] = [];
      }
    }
    final seen = <int>{};
    for (final day in days) {
      if (day is! Map || day['dayOfWeek'] is! int || day['slots'] is! List) {
        continue;
      }
      final weekday = day['dayOfWeek'] as int;
      if (weekday < 1 || weekday > 7) continue;
      final date = start.add(Duration(days: (weekday - start.weekday + 7) % 7));
      final dateText = _day(date);
      if (!seen.add(weekday)) {
        known.remove(dateText);
        continue;
      }
      if (date.isBefore(today) || date.difference(today).inDays >= 7) continue;
      final slots = day['slots'] as List;
      if (slots.length > 32) {
        known.remove(dateText);
        continue;
      }
      final courses = <Map<String, Object?>>[];
      var valid = true;
      for (final slot in slots) {
        if (slot is! Map ||
            slot['courseName'] is! String ||
            (slot['date'] != null && slot['date'] != dateText)) {
          valid = false;
          break;
        }
        if (slot['changeType'] == 'cancelled' ||
            (slot['weeks'] is List &&
                !(slot['weeks'] as List).contains(weekNumber)) ||
            (slot['weekExceptions'] is List &&
                (slot['weekExceptions'] as List).contains(weekNumber))) {
          continue;
        }
        final name = _short(slot['courseName'], 120);
        if (name.isEmpty) {
          valid = false;
          break;
        }
        final clock = RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');
        final from = slot['timeStart'];
        final to = slot['timeEnd'];
        final timed =
            from is String &&
            to is String &&
            clock.hasMatch(from) &&
            clock.hasMatch(to) &&
            from.compareTo(to) < 0;
        courses.add({
          'name': name,
          'location': _short(slot['location'] ?? slot['room'], 120),
          'label': timed
              ? '$from–$to'
              : '${_short(slot['start'], 40)}–${_short(slot['end'], 40)}',
          if (timed) 'start': from,
          if (timed) 'end': to,
        });
      }
      if (valid) {
        known[dateText] = courses;
      } else {
        known.remove(dateText);
      }
    }
  }

  final weeks = raw['termWeeks'];
  if (weeks is List) {
    for (final week in weeks.take(100)) {
      if (week is Map) addWeek(week, explicitEmpty: true);
    }
  }
  addWeek(raw);
  for (final date in conflicts) {
    known.remove(date);
  }
  return {
    'version': 1,
    'timeZone': zone,
    'fetchedAt': cached.fetchedAt.millisecondsSinceEpoch,
    'freshUntil':
        cached.freshUntil?.millisecondsSinceEpoch ??
        cached.fetchedAt.millisecondsSinceEpoch,
    'days': [
      for (var i = 0; i < 7; i++)
        {
          'date': _day(today.add(Duration(days: i))),
          'known': known.containsKey(_day(today.add(Duration(days: i)))),
          'courses': known[_day(today.add(Duration(days: i)))] ?? const [],
        },
    ],
  };
}
