// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ClassroomAvailable {
  const ClassroomAvailable({
    this.date,
    this.start,
    this.end,
    this.items,
  });

  final String? date;
  final String? start;
  final String? end;
  final List<ClassroomAvailableItems>? items;
}

class ClassroomAvailableItems {
  const ClassroomAvailableItems({
    this.campus,
    required this.building,
    required this.room,
    this.capacity,
    this.equipment,
    this.occupied,
    this.status,
  });

  final String? campus;
  final String building;
  final String room;
  final int? capacity;
  final List<String>? equipment;
  final bool? occupied;
  final String? status;
}
