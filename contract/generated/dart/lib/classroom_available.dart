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

  /// 实际采用的查询日历日，格式为 YYYY-MM-DD；未使用日历日轴时省略。
  final String? date;
  /// 实际采用的学期标识；未使用或来源未提供时省略。
  final String? term;
  /// 实际采用的教学周序号，从 1 开始；未使用教学周轴时省略。
  final int? week;
  /// 实际采用的星期序号，1=周一至 7=周日；未使用时省略。
  final int? weekday;
  /// 实际采用的墙钟窗口起点，推荐格式 HH:mm；未使用墙钟窗口时省略。
  final String? start;
  /// 实际采用的墙钟窗口终点，推荐格式 HH:mm；未使用墙钟窗口时省略。
  final String? end;
  /// IANA 时区；adapter 声明；有墙钟字段时应填
  final String? timeZone;
  /// 实际采用的节次窗口起点（含），从 1 开始；未使用节次窗口时省略。
  final int? sectionStart;
  /// 实际采用的节次窗口终点（含），从 1 开始；未使用节次窗口时省略。
  final int? sectionEnd;
  /// 空教室数据的来源系统名称或标识；缺失表示来源未提供。
  final String? sourceSystem;
  /// 空教室数据在来源系统中的更新时间，格式为 RFC3339/UTC；缺失表示来源未提供。
  final String? updatedAt;
  /// 符合查询条件的教室列表；无匹配教室时可为空数组。
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

  /// 教室所属校区；缺失表示来源未提供。
  final String? campus;
  /// 教学楼展示名；禁止空串；未知填 "-"
  final String building;
  /// 教学楼在校内系统中的标识或代码；缺失表示来源未提供。
  final String? buildingId;
  /// 教室展示名；禁止空串；未知填 "-"
  final String room;
  /// 教室在校内系统中的标识；缺失表示来源未提供。
  final String? roomId;
  /// 楼层，字符串以兼容「B1」「东3」等
  final String? floor;
  /// 教室容纳人数，单位为人；缺失表示来源未提供。
  final int? capacity;
  /// 教室设备名称列表；缺失表示来源未提供设备信息。
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

  /// 节次序号，从 1 开始，最大为 24。
  final int index;
  /// 该节次是否被占用。
  final bool occupied;
  /// 展示用，如「第3节」
  final String? label;
  /// 该节墙钟起点，推荐 HH:mm；解释时区见顶栏 timeZone
  final String? timeStart;
  /// 该节墙钟终点，推荐 HH:mm
  final String? timeEnd;
}
