/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

ExamList? examListFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null || !optionalIs<String>(map, 'term')) return null;
  final itemsRaw = map['items'];
  if (map.containsKey('items') && itemsRaw is! List) return null;
  final items = <ExamListItems>[];
  if (itemsRaw is List) {
    for (final rawItem in itemsRaw) {
      final item = _examItem(rawItem);
      if (item != null) items.add(item);
    }
  }
  return ExamList(
    term: map['term'] as String?,
    items: itemsRaw == null ? null : items,
  );
}

ExamListItems? _examItem(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final courseName = map['courseName'];
  if (courseName is! String || courseName.isEmpty) return null;
  for (final field in const [
    'courseId',
    'campus',
    'building',
    'room',
    'seat',
    'examType',
    'changeReason',
  ]) {
    if (!optionalIs<String>(map, field)) return null;
  }
  final examAt = optionalUtcDateTime(map, 'examAt');
  if (map.containsKey('examAt') && examAt == null) return null;
  final status = map['status'];
  if (status != null &&
      (status is! String || !_examStatuses.contains(status))) {
    return null;
  }
  return ExamListItems(
    courseId: map['courseId'] as String?,
    courseName: courseName,
    examAt: examAt,
    campus: map['campus'] as String?,
    building: map['building'] as String?,
    room: map['room'] as String?,
    seat: map['seat'] as String?,
    examType: map['examType'] as String?,
    status: status as String?,
    changeReason: map['changeReason'] as String?,
  );
}

const Set<String> _examStatuses = {
  'scheduled',
  'changed',
  'cancelled',
  'completed',
  'unknown',
};
