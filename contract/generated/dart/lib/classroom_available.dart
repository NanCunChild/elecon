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
    this.appliedFilters,
    this.coverage,
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
  /// 学校脚本实际采用的字段值；缺失表示来源不提供回显，不可猜测为请求原值。
  final Map<String, Object>? appliedFilters;
  /// 实际查询条件范围的完整性证据；缺失表示完整性未知，不是完整或空结果。
  final ClassroomAvailableCoverage? coverage;
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
    this.intervals,
    this.roomType,
    this.teachingCapacity,
    this.examCapacity,
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
  /// 已知绝对时段，左闭右开；同教室不得重叠，结束晚于开始；缺口为未知，不从节间或无课程推断开放。省略表示仅有旧聚合/节次数据。
  final List<ClassroomAvailableItemsIntervals>? intervals;
  /// 学校教室类型；缺失表示未知，不生成通用默认类型。
  final ClassroomAvailableItemsRoomType? roomType;
  /// 教学布置的座位容量，单位人；缺失表示未知，不能以0代替或继承考试容量。
  final int? teachingCapacity;
  /// 考试布置的座位容量，单位人；缺失表示未知，不能以0代替或继承教学容量。
  final int? examCapacity;
}

class ClassroomAvailableCoverage {
  const ClassroomAvailableCoverage({
    required this.complete,
    this.description,
  });

  /// 是否已完整覆盖实际采用条件的查询范围；true不等于查询全校，false表示仅部分结果。
  final bool complete;
  /// 可选纯文本范围和不完整原因说明；不用于推断未返回教室的状态。
  final String? description;
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

class ClassroomAvailableItemsIntervals {
  const ClassroomAvailableItemsIntervals({
    required this.startAt,
    required this.endAt,
    required this.status,
    this.reason,
  });

  /// 区间起点（含），RFC3339/UTC；必须是查询日对应的真实时刻。
  final String startAt;
  /// 区间终点（不含），RFC3339/UTC；必须晚于 startAt。
  final String endAt;
  /// 本区间无占用记录、占用或无法确认；available 不保证实际开门或允许使用。
  final String status;
  /// 学校脚本提供的状态依据或原因，纯文本；缺失表示来源未提供，宿主不得猜测。
  final String? reason;
}

class ClassroomAvailableItemsRoomType {
  const ClassroomAvailableItemsRoomType({
    required this.label,
    this.code,
  });

  /// 学校提供的教室类型名称，不据名称推断设备或用途权限。
  final String label;
  /// 学校作用域的类型代码；缺失表示来源未提供，不能以label替代。
  final String? code;
}
