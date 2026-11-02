/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

CalendarAcademic? calendarAcademicFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null ||
      !optionalIs<String>(map, 'term') ||
      !optionalIs<String>(map, 'startDate') ||
      !optionalIs<String>(map, 'endDate')) {
    return null;
  }
  final currentWeek = asInt(map['currentWeek']);
  if (map.containsKey('currentWeek') &&
      (map['currentWeek'] is! num || currentWeek == null || currentWeek < 1)) {
    return null;
  }
  return CalendarAcademic(
    term: map['term'] as String?,
    startDate: map['startDate'] as String?,
    endDate: map['endDate'] as String?,
    currentWeek: currentWeek,
  );
}
