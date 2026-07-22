// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ClassroomAvailable {
  const ClassroomAvailable({
    this.date,
    this.term,
    this.week,
    this.weekday,
    this.start,
    this.end,
    this.timeZone,
    this.sectionStart,
    this.sectionEnd,
    this.sourceSystem,
    this.updatedAt,
    this.items,
  });

  final String? date;
  final String? term;
  final int? week;
  final int? weekday;
  final String? start;
  final String? end;
  /// IANA 时区；adapter 声明；有墙钟字段时应填
  final String? timeZone;
  final int? sectionStart;
  final int? sectionEnd;
  final String? sourceSystem;
  final String? updatedAt;
  final List<ClassroomAvailableItems>? items;
}

class ClassroomAvailableItems {
  const ClassroomAvailableItems({
    this.campus,
    required this.building,
    this.buildingId,
    required this.room,
    this.roomId,
    this.floor,
    this.capacity,
    this.equipment,
    this.occupied,
    this.status,
    this.sections,
  });

  final String? campus;
  /// 教学楼展示名；禁止空串；未知填 "-"
  final String building;
  final String? buildingId;
  /// 教室展示名；禁止空串；未知填 "-"
  final String room;
  final String? roomId;
  /// 楼层，字符串以兼容「B1」「东3」等
  final String? floor;
  final int? capacity;
  final List<String>? equipment;
  /// 在查询窗口上的聚合占用；无窗口则「当日是否曾占用」由 adapter 定义并尽量文档化
  final bool? occupied;
  /// available=窗口内全空闲；occupied=窗口内全占用；partial=窗口内部分节次占用；unknown=无法判定
  final String? status;
  /// 分节占用；缺失=该校不提供节次粒度；至多 24 节
  final List<ClassroomAvailableItemsSections>? sections;
}

class ClassroomAvailableItemsSections {
  const ClassroomAvailableItemsSections({
    required this.index,
    required this.occupied,
    this.label,
    this.timeStart,
    this.timeEnd,
  });

  final int index;
  final bool occupied;
  /// 展示用，如「第3节」
  final String? label;
  /// 该节墙钟起点，推荐 HH:mm；解释时区见顶栏 timeZone
  final String? timeStart;
  /// 该节墙钟终点，推荐 HH:mm
  final String? timeEnd;
}
