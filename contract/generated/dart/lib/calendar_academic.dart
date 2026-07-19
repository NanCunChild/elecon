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

  final String? term;
  final String? startDate;
  final String? endDate;
  final int? currentWeek;
  final List<CalendarAcademicHolidays>? holidays;
}

class CalendarAcademicHolidays {
  const CalendarAcademicHolidays({
    required this.date,
    required this.name,
    this.isTeachingDay,
  });

  final String date;
  final String name;
  final bool? isTeachingDay;
}
