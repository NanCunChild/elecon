/// ADR-074: standard fields only; open-schema extensions never leave this port.
library;

class AiQueryInput {
  const AiQueryInput(this.params, {this.start, this.end});
  final Map<String, dynamic> params;
  final DateTime? start;
  final DateTime? end;

  factory AiQueryInput.parse(String function, Map<String, Object?> raw) {
    switch (function) {
      case 'getGrades':
        _keys(raw, {'term'});
        return AiQueryInput({'term': _identifier(raw['term'])});
      case 'getSchedule':
        _keys(raw, {'term', 'week'});
        final week = raw['week'];
        if (week is! int || week < 1 || week > 100) _invalid();
        return AiQueryInput({'term': _identifier(raw['term']), 'week': week});
      case 'findAvailableClassrooms':
        _keys(raw, {'startAt', 'endAt', 'buildingId'});
        final start = _minuteInstant(raw['startAt']);
        final end = _minuteInstant(raw['endAt']);
        final startText = raw['startAt'] as String;
        final endText = raw['endAt'] as String;
        if (!end.isAfter(start) ||
            end.difference(start).inMinutes > 720 ||
            startText.substring(0, 10) != endText.substring(0, 10) ||
            startText.substring(19) != endText.substring(19)) {
          _invalid();
        }
        return AiQueryInput(
          {
            'date': startText.substring(0, 10),
            'start': startText.substring(11, 16),
            'end': endText.substring(11, 16),
            if (raw['buildingId'] != null)
              'buildingId': _identifier(raw['buildingId']),
          },
          start: start,
          end: end,
        );
      default:
        _invalid();
    }
  }
}

void _keys(Map<String, Object?> raw, Set<String> allowed) {
  if (raw.keys.any((k) => !allowed.contains(k))) _invalid();
}

String _identifier(Object? value) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > 128 ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
    _invalid();
  }
  return value;
}

Never _invalid() => throw const FormatException('invalid_query');

DateTime _minuteInstant(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:00(?:Z|[+-](?:0\d|1[0-4]):[0-5]\d)$',
      ).hasMatch(value)) {
    _invalid();
  }
  final y = int.parse(value.substring(0, 4));
  final m = int.parse(value.substring(5, 7));
  final d = int.parse(value.substring(8, 10));
  final date = DateTime.utc(y, m, d);
  if (y < 1 ||
      date.year != y ||
      date.month != m ||
      date.day != d ||
      (value.length > 20 &&
          value.substring(20, 22) == '14' &&
          value.substring(23) != '00')) {
    _invalid();
  }
  return DateTime.parse(value);
}

class AiQueryProjection {
  const AiQueryProjection(
    this.data, {
    required this.partial,
    required this.empty,
  });
  final Map<String, Object?> data;
  final bool partial;
  final bool empty;
}

Map<String, Object?> _map(Object? raw) {
  if (raw is! Map || raw.keys.any((k) => k is! String)) _invalid();
  return Map<String, Object?>.from(raw);
}

List<Object?> _list(Object? raw) {
  if (raw is! List) _invalid();
  return raw;
}

Object? _primitive(Object? value) {
  if (value == null || value is bool || value is num && value.isFinite) {
    return value;
  }
  if (value is String && value.length <= 4096) return value;
  _invalid();
}

Map<String, Object?> _pick(Map<String, Object?> raw, String fields) => {
  for (final key in fields.split(' '))
    if (raw.containsKey(key) && raw[key] != null) key: _primitive(raw[key]),
};

AiQueryProjection projectAiQuery(
  String function,
  Object? raw,
  AiQueryInput input,
) {
  final data = _map(raw);
  switch (function) {
    case 'getGrades':
      if (data['term'] != input.params['term']) _invalid();
      final rows = _list(data['items']);
      final items = <Object?>[
        for (final row in rows.take(200)) _grade(_map(row)),
      ];
      final total = data['total'];
      final partial =
          rows.length > 200 ||
          data['hasNext'] != false ||
          data['page'] is num && (data['page'] as num) > 1 ||
          total is num && total > rows.length;
      return AiQueryProjection(
        {
          ..._pick(
            data,
            'term academicYear termName updatedAt page size total hasNext gradePointScale',
          ),
          'items': items,
          'coverage': 'returnedPage',
        },
        partial: partial,
        empty: items.isEmpty,
      );
    case 'getSchedule':
      if (data['term'] != input.params['term'] ||
          data['week'] != input.params['week']) {
        _invalid();
      }
      final days = _list(data['days']);
      if (days.length > 7) _invalid();
      var count = 0;
      var partial = false;
      final seenDays = <int>{};
      final projectedDays = <Object?>[];
      for (final dayRaw in days) {
        final day = _map(dayRaw);
        final dayOfWeek = day['dayOfWeek'];
        if (dayOfWeek is! int ||
            dayOfWeek < 1 ||
            dayOfWeek > 7 ||
            !seenDays.add(dayOfWeek)) {
          _invalid();
        }
        final slots = <Object?>[];
        for (final raw in _list(day['slots'])) {
          if (count++ >= 200) {
            partial = true;
            continue;
          }
          slots.add(
            _pick(
              _map(raw),
              'start end courseName courseId date timeStart timeEnd campus building room teacher location changeType changeReason',
            ),
          );
        }
        projectedDays.add({'dayOfWeek': dayOfWeek, 'slots': slots});
      }
      return AiQueryProjection(
        {
          ..._pick(
            data,
            'term week academicYear termStartDate termEndDate teachingWeekStart teachingWeekEnd weekType updatedAt sourceSystem',
          ),
          'days': projectedDays,
          'coverage': 'requestedTeachingWeek',
        },
        partial: partial,
        empty: count == 0,
      );
    case 'findAvailableClassrooms':
      if (data['date'] != input.params['date']) _invalid();
      final rows = _list(data['items']);
      var unknown = 0;
      final items = <Object?>[];
      var matching = 0;
      for (final raw in rows) {
        final room = _map(raw);
        final coverage = _availableCoverage(
          room['intervals'],
          input.start!,
          input.end!,
        );
        if (coverage == null) unknown++;
        if (coverage != true) continue;
        matching++;
        if (items.length >= 200) continue;
        items.add({
          ..._pick(
            room,
            'campus building buildingId room roomId floor capacity',
          ),
          'status': 'available',
          'intervals': [
            for (final interval in _list(room['intervals']))
              _pick(_map(interval), 'startAt endAt status reason'),
          ],
        });
      }
      return AiQueryProjection(
        {
          ..._pick(
            data,
            'date term week weekday start end timeZone sourceSystem updatedAt',
          ),
          'items': items,
          'coverage': 'returnedRooms',
          'unknownRooms': unknown,
          'evaluatedRooms': rows.length,
          'entryPermission': 'notEstablished',
          'startAt': input.start!.toUtc().toIso8601String(),
          'endAt': input.end!.toUtc().toIso8601String(),
        },
        partial: unknown > 0 || matching > 200,
        empty: items.isEmpty,
      );
    default:
      _invalid();
  }
}

Map<String, Object?> _grade(Map<String, Object?> row) => {
  ..._pick(
    row,
    'courseId courseName credit creditType courseNature courseCategory courseGroup language teacher offeringUnit classNo sectionNo examMethod examAt retake sourceStatus gradePoint gradePointSource category status',
  ),
  'score': _pick(_map(row['score']), 'kind value raw status max'),
};

/// null means missing or contradictory evidence; false is known occupancy.
bool? _availableCoverage(Object? raw, DateTime start, DateTime end) {
  if (raw is! List || raw.isEmpty || raw.length > 96) return null;
  final intervals = <({DateTime start, DateTime end, String status})>[];
  for (final item in raw) {
    if (item is! Map ||
        item['startAt'] is! String ||
        item['endAt'] is! String ||
        !const {'available', 'occupied', 'unknown'}.contains(item['status'])) {
      return null;
    }
    final a = _sourceInstant(item['startAt'] as String);
    final b = _sourceInstant(item['endAt'] as String);
    if (a == null || b == null || !a.isUtc || !b.isUtc || !b.isAfter(a)) {
      return null;
    }
    intervals.add((start: a, end: b, status: item['status'] as String));
  }
  intervals.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < intervals.length; i++) {
    if (intervals[i].start.isBefore(intervals[i - 1].end)) return null;
  }
  var cursor = start;
  for (final interval in intervals) {
    if (!interval.end.isAfter(cursor) || !interval.start.isBefore(end)) {
      continue;
    }
    if (interval.start.isAfter(cursor) || interval.status == 'unknown') {
      return null;
    }
    if (interval.status == 'occupied') return false;
    cursor = interval.end;
    if (!cursor.isBefore(end)) return true;
  }
  return null;
}

DateTime? _sourceInstant(String text) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(Z|[+-](?:0\d|1[0-4]):[0-5]\d)$',
  ).firstMatch(text);
  if (match == null || match.end != text.length) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  final offset = match[4]!;
  if (year < 1 ||
      date.year != year ||
      date.month != month ||
      date.day != day ||
      offset.length > 1 &&
          offset.substring(1, 3) == '14' &&
          offset.substring(4) != '00') {
    return null;
  }
  return DateTime.tryParse(text);
}
