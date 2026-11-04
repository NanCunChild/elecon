/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

ScheduleWeek? scheduleWeekFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final term = map['term']?.toString();
  final week = asInt(map['week']);
  if (term == null || term.isEmpty || week == null) return null;
  final daysRaw = map['days'];
  final days = <ScheduleWeekDays>[];
  if (daysRaw is List) {
    for (final entry in daysRaw) {
      final day = _scheduleDay(entry);
      if (day != null) days.add(day);
    }
  }
  return ScheduleWeek(
    term: term,
    week: week,
    academicYear: map['academicYear']?.toString(),
    termStartDate: map['termStartDate']?.toString(),
    termEndDate: map['termEndDate']?.toString(),
    teachingWeekStart: map['teachingWeekStart']?.toString(),
    teachingWeekEnd: map['teachingWeekEnd']?.toString(),
    weekType: map['weekType']?.toString(),
    timeSegments: _scheduleSegments(map['timeSegments']),
    weekPreviews: _schedulePreviews(map['weekPreviews']),
    termWeeks: _scheduleTermWeeks(map['termWeeks']),
    updatedAt: map['updatedAt']?.toString(),
    sourceSystem: map['sourceSystem']?.toString(),
    days: days,
  );
}

List<ScheduleWeekTimeSegments>? _scheduleSegments(Object? raw) {
  if (raw is! List || raw.length > 48) return null;
  final result = <ScheduleWeekTimeSegments>[];
  var previousEnd = '';
  final clock = RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');
  for (final entry in raw) {
    final map = asStringKeyedMap(entry);
    final label = map?['label'];
    final start = map?['timeStart'];
    final end = map?['timeEnd'];
    if (label is! String ||
        label.isEmpty ||
        label.length > 40 ||
        start is! String ||
        end is! String ||
        !clock.hasMatch(start) ||
        !clock.hasMatch(end) ||
        start.compareTo(end) >= 0 ||
        start.compareTo(previousEnd) < 0) {
      // A broken hint must never erase valid courses or invent their times.
      return null;
    }
    previousEnd = end;
    result.add(
      ScheduleWeekTimeSegments(label: label, timeStart: start, timeEnd: end),
    );
  }
  return result;
}

List<ScheduleWeekWeekPreviews>? _schedulePreviews(Object? raw) {
  if (raw is! List || raw.length > 100) return null;
  final result = <ScheduleWeekWeekPreviews>[];
  final seenWeeks = <int>{};
  for (final entry in raw) {
    final map = asStringKeyedMap(entry);
    final week = asInt(map?['week']);
    final days = map?['days'];
    if (week == null ||
        week < 1 ||
        week > 100 ||
        !seenWeeks.add(week) ||
        days is! List ||
        days.length > 7) {
      return null;
    }
    final knownDays = <ScheduleWeekWeekPreviewsDays>[];
    final seenDays = <int>{};
    for (final rawDay in days) {
      final day = asStringKeyedMap(rawDay);
      final weekday = asInt(day?['dayOfWeek']);
      final count = asInt(day?['courseCount']);
      if (weekday == null ||
          weekday < 1 ||
          weekday > 7 ||
          !seenDays.add(weekday) ||
          count == null ||
          count < 0 ||
          count > 1000) {
        return null;
      }
      knownDays.add(
        ScheduleWeekWeekPreviewsDays(dayOfWeek: weekday, courseCount: count),
      );
    }
    result.add(ScheduleWeekWeekPreviews(week: week, days: knownDays));
  }
  return result;
}

ScheduleWeekDays? _scheduleDay(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final dayOfWeek = asInt(map['dayOfWeek']);
  if (dayOfWeek == null) return null;
  final slotsRaw = map['slots'];
  final slots = <ScheduleWeekDaysSlots>[];
  if (slotsRaw is List) {
    for (final entry in slotsRaw) {
      final slot = _scheduleSlot(entry);
      if (slot != null) slots.add(slot);
    }
  }
  return ScheduleWeekDays(dayOfWeek: dayOfWeek, slots: slots);
}

ScheduleWeekDaysSlots? _scheduleSlot(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final start = map['start']?.toString();
  final end = map['end']?.toString();
  final courseName = map['courseName']?.toString();
  if (start == null ||
      start.isEmpty ||
      end == null ||
      end.isEmpty ||
      courseName == null ||
      courseName.isEmpty) {
    return null;
  }
  return ScheduleWeekDaysSlots(
    start: start,
    end: end,
    courseName: courseName,
    courseId: map['courseId']?.toString(),
    date: map['date']?.toString(),
    timeStart: map['timeStart']?.toString(),
    timeEnd: map['timeEnd']?.toString(),
    campus: map['campus']?.toString(),
    building: map['building']?.toString(),
    room: map['room']?.toString(),
    courseNature: map['courseNature']?.toString(),
    classNo: map['classNo']?.toString(),
    teacher: map['teacher']?.toString(),
    location: map['location']?.toString(),
    roomCapacity: asInt(map['roomCapacity']),
    language: map['language']?.toString(),
    courseUrl: map['courseUrl']?.toString(),
    group: map['group']?.toString(),
    onlineUrl: map['onlineUrl']?.toString(),
    meetingNumberPresent: map['meetingNumberPresent'] is bool
        ? map['meetingNumberPresent'] as bool
        : null,
    meetingPasswordPresent: map['meetingPasswordPresent'] is bool
        ? map['meetingPasswordPresent'] as bool
        : null,
    changeType: map['changeType']?.toString(),
    changeReason: map['changeReason']?.toString(),
    weeks: map['weeks'] is List
        ? (map['weeks'] as List).map(asInt).whereType<int>().toList()
        : null,
    weekExceptions: map['weekExceptions'] is List
        ? (map['weekExceptions'] as List).map(asInt).whereType<int>().toList()
        : null,
  );
}

List<ScheduleWeekTermWeeks>? _scheduleTermWeeks(Object? raw) {
  if (raw is! List || raw.length > 100) return null;
  final weeks = <ScheduleWeekTermWeeks>[];
  final seen = <int>{};
  for (final entry in raw) {
    final map = asStringKeyedMap(entry);
    final week = asInt(map?['week']);
    final start = map?['teachingWeekStart'];
    final end = map?['teachingWeekEnd'];
    if (week == null ||
        week < 1 ||
        week > 100 ||
        !seen.add(week) ||
        start is! String ||
        end is! String ||
        map?['days'] is! List) {
      return null;
    }
    weeks.add(
      ScheduleWeekTermWeeks(
        week: week,
        teachingWeekStart: start,
        teachingWeekEnd: end,
        weekType: map?['weekType'] as String?,
        days: [
          for (final rawDay in map!['days'] as List)
            if (_scheduleDay(rawDay) case final day?)
              ScheduleWeekTermWeeksDays(
                dayOfWeek: day.dayOfWeek,
                slots: [
                  for (final slot in day.slots)
                    ScheduleWeekTermWeeksDaysSlots(
                      start: slot.start,
                      end: slot.end,
                      courseName: slot.courseName,
                      courseId: slot.courseId,
                      date: slot.date,
                      timeStart: slot.timeStart,
                      timeEnd: slot.timeEnd,
                      campus: slot.campus,
                      building: slot.building,
                      room: slot.room,
                      roomCapacity: slot.roomCapacity,
                      courseNature: slot.courseNature,
                      classNo: slot.classNo,
                      language: slot.language,
                      courseUrl: slot.courseUrl,
                      group: slot.group,
                      onlineUrl: slot.onlineUrl,
                      meetingNumberPresent: slot.meetingNumberPresent,
                      meetingPasswordPresent: slot.meetingPasswordPresent,
                      changeType: slot.changeType,
                      changeReason: slot.changeReason,
                      weekExceptions: slot.weekExceptions,
                      teacher: slot.teacher,
                      location: slot.location,
                      weeks: slot.weeks,
                    ),
                ],
              ),
        ],
      ),
    );
  }
  return weeks;
}
