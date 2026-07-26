// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ScheduleWeek {
  const ScheduleWeek({
    required this.term,
    this.academicYear,
    this.termStartDate,
    this.termEndDate,
    this.teachingWeekStart,
    this.teachingWeekEnd,
    this.weekType,
    this.updatedAt,
    this.sourceSystem,
    required this.week,
    required this.days,
  });

  /// 学期标识，如 2025-2026-2。
  final String term;
  /// 课表所属学年；缺失表示来源未提供。
  final String? academicYear;
  /// 学期开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? termStartDate;
  /// 学期结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? termEndDate;
  /// 本教学周开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? teachingWeekStart;
  /// 本教学周结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? teachingWeekEnd;
  /// 周次类型：教学周、考试周、假期或未知；缺失表示来源未提供。
  final String? weekType;
  /// 课表数据更新时间，RFC3339/UTC；缺失表示来源未提供。
  final String? updatedAt;
  /// 课表数据的来源系统；缺失表示来源未提供。
  final String? sourceSystem;
  /// 教学周序号，从 1 开始。
  final int week;
  /// 本周按星期组织的课表。
  final List<ScheduleWeekDays> days;
}

class ScheduleWeekDays {
  const ScheduleWeekDays({
    required this.dayOfWeek,
    required this.slots,
  });

  /// 星期序号，1 至 7。
  final int dayOfWeek;
  /// 当天的课程时段列表。
  final List<ScheduleWeekDaysSlots> slots;
}

class ScheduleWeekDaysSlots {
  const ScheduleWeekDaysSlots({
    required this.start,
    required this.end,
    required this.courseName,
    this.courseId,
    this.date,
    this.timeStart,
    this.timeEnd,
    this.campus,
    this.building,
    this.room,
    this.roomCapacity,
    this.courseNature,
    this.classNo,
    this.language,
    this.courseUrl,
    this.group,
    this.onlineUrl,
    this.meetingNumberPresent,
    this.meetingPasswordPresent,
    this.changeType,
    this.changeReason,
    this.weekExceptions,
    this.teacher,
    this.location,
    this.weeks,
  });

  /// 课程开始节次标签。
  final String start;
  /// 课程结束节次标签。
  final String end;
  /// 课程名称。
  final String courseName;
  /// 校内作用域的课程标识；缺失表示来源未提供。
  final String? courseId;
  /// 本次课程的日历日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? date;
  /// 课程开始墙钟时间或节次标签；缺失表示来源未提供。
  final String? timeStart;
  /// 课程结束墙钟时间或节次标签；缺失表示来源未提供。
  final String? timeEnd;
  /// 上课校区；缺失表示来源未提供。
  final String? campus;
  /// 上课楼栋；缺失表示来源未提供。
  final String? building;
  /// 上课教室；缺失表示来源未提供。
  final String? room;
  /// 教室容量，单位为人数；缺失表示来源未提供。
  final int? roomCapacity;
  /// 学校定义的课程性质；缺失表示来源未提供。
  final String? courseNature;
  /// 教学班号；缺失表示来源未提供。
  final String? classNo;
  /// 课程教学语言；缺失表示来源未提供。
  final String? language;
  /// 课程页面链接；缺失表示来源未提供。
  final String? courseUrl;
  /// 合班或分组信息；缺失表示来源未提供。
  final String? group;
  /// 线上课程地址；缺失表示来源未提供。
  final String? onlineUrl;
  /// 来源是否提供会议号；仅表示是否存在，不包含会议号值。
  final bool? meetingNumberPresent;
  /// 来源是否提供会议密码；仅表示是否存在，不包含密码值。
  final bool? meetingPasswordPresent;
  /// 课程变更类型：无变更、调课、停课、补课、代课、临时教室或未知；缺失表示来源未提供。
  final String? changeType;
  /// 课程安排变更原因；缺失表示来源未提供。
  final String? changeReason;
  final List<int>? weekExceptions;
  /// 授课教师；缺失表示来源未提供。
  final String? teacher;
  /// 来源提供的非结构化上课地点；缺失表示来源未提供。
  final String? location;
  /// 该课程实际上课的教学周序号列表；缺失表示来源未提供。
  final List<int>? weeks;
}
