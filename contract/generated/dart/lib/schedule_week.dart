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

  final String term;
  final String? academicYear;
  final String? termStartDate;
  final String? termEndDate;
  final String? teachingWeekStart;
  final String? teachingWeekEnd;
  final String? weekType;
  final String? updatedAt;
  final String? sourceSystem;
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

  final String start;
  final String end;
  final String courseName;
  final String? courseId;
  final String? date;
  final String? timeStart;
  final String? timeEnd;
  final String? campus;
  final String? building;
  final String? room;
  final int? roomCapacity;
  final String? courseNature;
  final String? classNo;
  final String? language;
  final String? courseUrl;
  final String? group;
  final String? onlineUrl;
  final bool? meetingNumberPresent;
  final bool? meetingPasswordPresent;
  final String? changeType;
  final String? changeReason;
  final List<int>? weekExceptions;
  final String? teacher;
  final String? location;
  final List<int>? weeks;
}
