/// RFC 5545 export, using explicit school zones and UTC event instants.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:elecon_contract/schedule_week.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;
import 'personal_course.dart';

bool _initialized = false;
tz.Location scheduleTimeZone(String? zone) {
  if (!_initialized) {
    data.initializeTimeZones();
    _initialized = true;
  }
  if (zone == null) throw const FormatException('schedule_timezone_unknown');
  try {
    return tz.getLocation(zone);
  } catch (_) {
    throw const FormatException('schedule_timezone_unknown');
  }
}

DateTime? scheduleDate(String? text) {
  if (text == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    return null;
  }
  final date = DateTime.tryParse('${text}T00:00:00Z');
  return date != null && date.toIso8601String().startsWith(text) ? date : null;
}

String _escape(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', r'\n')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,');
String _stamp(DateTime date) =>
    '${date.toUtc().toIso8601String().split('.').first.replaceAll('-', '').replaceAll(':', '')}Z';

// Fold at 75 octets; continuation whitespace counts and UTF-8 scalars stay whole.
String _fold(String line) {
  final out = StringBuffer();
  var size = 0;
  for (final rune in line.runes) {
    final text = String.fromCharCode(rune),
        count = utf8.encode(String.fromCharCode(rune)).length;
    if (size + count > 75) {
      out.write('\r\n ');
      size = 1;
    }
    out.write(text);
    size += count;
  }
  return out.toString();
}

class ScheduleCalendarExport {
  const ScheduleCalendarExport(this.text, this.count, this.skipped);
  final String text;
  final int count, skipped;
}

ScheduleCalendarExport exportScheduleCalendar(
  ScheduleWeek schedule, {
  required String sourceId,
  bool wholeTerm = false,
  int? reminderMinutes,
  List<PersonalCourse> personal = const [],
  DateTime? stamp,
}) {
  if (reminderMinutes != null &&
      (reminderMinutes < 0 || reminderMinutes > 1440)) {
    throw const FormatException('schedule_reminder_invalid');
  }
  final zone = scheduleTimeZone(schedule.timeZone);
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//elecon//Personal Schedule//EN',
    'CALSCALE:GREGORIAN',
  ];
  final seen = <String>{};
  var skipped = 0;
  final exportedAt = _stamp(stamp ?? DateTime.now());
  void add(
    String name,
    String identity,
    String? date,
    String? start,
    String? end,
    String location,
  ) {
    final day = scheduleDate(date);
    final clock = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
    if (day == null ||
        start == null ||
        end == null ||
        !clock.hasMatch(start) ||
        !clock.hasMatch(end) ||
        start.compareTo(end) >= 0) {
      skipped++;
      return;
    }
    tz.TZDateTime time(String value) => tz.TZDateTime(
      zone,
      day.year,
      day.month,
      day.day,
      int.parse(value.substring(0, 2)),
      int.parse(value.substring(3)),
    );
    final from = time(start), to = time(end);
    // DST gaps normalize to another wall clock; do not silently move a lesson.
    if (from.hour != int.parse(start.substring(0, 2)) ||
        from.minute != int.parse(start.substring(3)) ||
        to.hour != int.parse(end.substring(0, 2)) ||
        to.minute != int.parse(end.substring(3)) ||
        !to.isAfter(from)) {
      skipped++;
      return;
    }
    final uid = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sourceId,
              schedule.term,
              identity,
              date,
              start,
              end,
              location,
            ]),
          ),
        )
        .toString();
    if (!seen.add(uid)) return;
    lines.addAll([
      'BEGIN:VEVENT',
      'UID:$uid@elecon',
      'DTSTAMP:$exportedAt',
      'DTSTART:${_stamp(from)}',
      'DTEND:${_stamp(to)}',
      'SUMMARY:${_escape(name)}',
      if (location.isNotEmpty) 'LOCATION:${_escape(location)}',
    ]);
    if (reminderMinutes != null) {
      lines.addAll([
        'BEGIN:VALARM',
        'ACTION:DISPLAY',
        'DESCRIPTION:${_escape(name)}',
        'TRIGGER:-PT${reminderMinutes}M',
        'END:VALARM',
      ]);
    }
    lines.add('END:VEVENT');
  }

  String? dayDate(String? weekStart, int day) {
    final start = scheduleDate(weekStart);
    if (start == null || day < 1 || day > 7) return null;
    return start
        .add(Duration(days: (day - start.weekday + 7) % 7))
        .toIso8601String()
        .substring(0, 10);
  }

  final start =
      schedule.teachingWeekStart ??
      (scheduleDate(schedule.termStartDate)
          ?.add(Duration(days: (schedule.week - 1) * 7))
          .toIso8601String()
          .substring(0, 10));
  for (final day in schedule.days) {
    for (final slot in day.slots) {
      if (slot.changeType == 'cancelled' ||
          (slot.weeks != null && !slot.weeks!.contains(schedule.week)) ||
          (slot.weekExceptions?.contains(schedule.week) ?? false)) {
        continue;
      }
      add(
        slot.courseName,
        slot.courseId ?? slot.courseName,
        slot.date ?? dayDate(start, day.dayOfWeek),
        slot.timeStart,
        slot.timeEnd,
        slot.location ??
            [
              slot.campus,
              slot.building,
              slot.room,
            ].whereType<String>().join(' · '),
      );
    }
  }
  if (wholeTerm) {
    for (final week in schedule.termWeeks ?? <ScheduleWeekTermWeeks>[]) {
      if (week.week == schedule.week) continue;
      for (final day in week.days) {
        for (final slot in day.slots) {
          if (slot.changeType == 'cancelled' ||
              (slot.weeks != null && !slot.weeks!.contains(week.week)) ||
              (slot.weekExceptions?.contains(week.week) ?? false)) {
            continue;
          }
          add(
            slot.courseName,
            slot.courseId ?? slot.courseName,
            slot.date ?? dayDate(week.teachingWeekStart, day.dayOfWeek),
            slot.timeStart,
            slot.timeEnd,
            slot.location ??
                [
                  slot.campus,
                  slot.building,
                  slot.room,
                ].whereType<String>().join(' · '),
          );
        }
      }
    }
  }
  final weekStart = scheduleDate(start);
  for (final course in personal) {
    final date = scheduleDate(course.date)!;
    if (!wholeTerm &&
        (weekStart == null ||
            date.isBefore(weekStart) ||
            !date.isBefore(weekStart.add(const Duration(days: 7))))) {
      continue;
    }
    if (wholeTerm) {
      final starts = [
        ?weekStart,
        for (final week in schedule.termWeeks ?? <ScheduleWeekTermWeeks>[])
          if (scheduleDate(week.teachingWeekStart) != null)
            scheduleDate(week.teachingWeekStart)!,
      ];
      if (!starts.any(
        (start) =>
            !date.isBefore(start) &&
            date.isBefore(start.add(const Duration(days: 7))),
      )) {
        continue;
      }
    }
    add(
      course.name,
      'personal:${course.id}',
      course.date,
      course.start,
      course.end,
      course.location,
    );
  }
  lines.add('END:VCALENDAR');
  return ScheduleCalendarExport(
    '${lines.map(_fold).join('\r\n')}\r\n',
    seen.length,
    skipped,
  );
}
