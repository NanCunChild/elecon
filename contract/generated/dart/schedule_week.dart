// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ScheduleWeek {
  const ScheduleWeek({
    required this.term,
    required this.week,
    required this.days,
  });

  final String term;
  final int week;
  final List<ScheduleWeekDays> days;
}

class ScheduleWeekDays {
  const ScheduleWeekDays({
    required this.dayOfWeek,
    required this.slots,
  });

  final int dayOfWeek;
  final List<ScheduleWeekDaysSlots> slots;
}

class ScheduleWeekDaysSlots {
  const ScheduleWeekDaysSlots({
    required this.start,
    required this.end,
    required this.courseName,
    this.courseId,
    this.teacher,
    this.location,
    this.weeks,
  });

  final String start;
  final String end;
  final String courseName;
  final String? courseId;
  final String? teacher;
  final String? location;
  final List<int>? weeks;
}
