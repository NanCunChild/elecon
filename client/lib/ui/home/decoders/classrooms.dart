/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

ClassroomBuildings? classroomBuildingsFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  final items = <ClassroomBuildingsItems>[];
  if (itemsRaw is List) {
    for (final entry in itemsRaw) {
      final m = asStringKeyedMap(entry);
      if (m == null) continue;
      final building = m['building']?.toString();
      if (building == null || building.isEmpty) continue;
      items.add(
        ClassroomBuildingsItems(
          building: building,
          buildingId: m['buildingId']?.toString(),
          campus: m['campus']?.toString(),
          roomCount: asInt(m['roomCount']),
        ),
      );
    }
  }
  return ClassroomBuildings(
    campus: map['campus']?.toString(),
    term: map['term']?.toString(),
    items: items,
  );
}

ClassroomAvailable? classroomAvailableFromDynamic(
  Object? raw, {
  String? schemaVersion,
}) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  final items = <ClassroomAvailableItems>[];
  if (itemsRaw is List) {
    for (final entry in itemsRaw) {
      final item = _classroomItem(
        entry,
        preciseIntervals: schemaVersion == '1.2',
      );
      if (item != null) items.add(item);
    }
  }
  return ClassroomAvailable(
    date: map['date']?.toString(),
    term: map['term']?.toString(),
    week: asInt(map['week']),
    weekday: asInt(map['weekday']),
    start: map['start']?.toString(),
    end: map['end']?.toString(),
    timeZone: map['timeZone']?.toString(),
    sourceSystem: map['sourceSystem']?.toString(),
    updatedAt: map['updatedAt']?.toString(),
    items: items,
  );
}

ClassroomAvailableItems? _classroomItem(
  Object? raw, {
  required bool preciseIntervals,
}) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final building = map['building']?.toString();
  final room = map['room']?.toString();
  if (building == null || building.isEmpty || room == null || room.isEmpty) {
    return null;
  }
  final sectionsRaw = map['sections'];
  List<ClassroomAvailableItemsSections>? sections;
  if (sectionsRaw is List) {
    final out = <ClassroomAvailableItemsSections>[];
    for (final entry in sectionsRaw) {
      final m = asStringKeyedMap(entry);
      if (m == null) continue;
      final index = asInt(m['index']);
      final occupied = m['occupied'];
      if (index == null || occupied is! bool) continue;
      out.add(
        ClassroomAvailableItemsSections(
          index: index,
          occupied: occupied,
          label: m['label']?.toString(),
          timeStart: m['timeStart']?.toString(),
          timeEnd: m['timeEnd']?.toString(),
        ),
      );
    }
    sections = out.isEmpty ? null : out;
  }
  return ClassroomAvailableItems(
    campus: map['campus']?.toString(),
    building: building,
    buildingId: map['buildingId']?.toString(),
    room: room,
    roomId: map['roomId']?.toString(),
    floor: map['floor']?.toString(),
    capacity: asInt(map['capacity']),
    equipment: asStringList(map['equipment']),
    occupied: map['occupied'] is bool ? map['occupied'] as bool : null,
    status: map['status']?.toString(),
    sections: sections,
    // 1.1 is open: a same-named extension has no 1.2 interval semantics.
    intervals: preciseIntervals && map['intervals'] is List
        ? [
            for (final raw in map['intervals'] as List)
              if (asStringKeyedMap(raw) case final interval?)
                ClassroomAvailableItemsIntervals(
                  startAt: interval['startAt']?.toString() ?? '',
                  endAt: interval['endAt']?.toString() ?? '',
                  status: interval['status']?.toString() ?? 'unknown',
                  reason: interval['reason']?.toString(),
                ),
          ]
        : null,
  );
}
