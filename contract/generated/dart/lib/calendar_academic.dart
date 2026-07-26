// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CalendarAcademic {
  const CalendarAcademic({
    this.term,
    this.startDate,
    this.endDate,
    this.currentWeek,
    this.holidays,
  });

  /// 校历所属学期标识；缺失表示来源未提供学期。
  final String? term;
  /// 学期开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? startDate;
  /// 学期结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? endDate;
  /// 当前教学周序号，从 1 开始；缺失表示来源未提供或无法确定。
  final int? currentWeek;
  /// 校历中的节假日条目列表；缺失表示来源未提供。
  final List<CalendarAcademicHolidays>? holidays;
}

class CalendarAcademicHolidays {
  const CalendarAcademicHolidays({
    required this.date,
    required this.name,
    this.isTeachingDay,
  });

  /// 条目对应的日历日，格式为 YYYY-MM-DD。
  final String date;
  /// 节假日名称。
  final String name;
  /// 该日是否按教学日安排；缺失表示来源未提供此判断。
  final bool? isTeachingDay;
}
