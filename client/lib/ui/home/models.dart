/// 首页数据模型（view model）。
///
/// 这些是 UI 层用于渲染的中间结构，**非** contract/schema 的权威定义。
/// TODO(codegen)：待 tools codegen 从 contract/schema/*.json 生成后，
///   本文件应替换为生成产物，消除与 schema 的手写漂移。
library;

class CampusSnapshot {
  const CampusSnapshot({
    required this.schoolName,
    required this.updatedAt,
    this.grades,
    this.schedule,
    this.notices,
    this.genericSections = const [],
  });

  final String schoolName;
  final DateTime updatedAt;
  final GradesList? grades;
  final ScheduleWeek? schedule;
  final NoticeList? notices;
  final List<GenericSection> genericSections;

  bool get isEmpty =>
      grades == null &&
      schedule == null &&
      notices == null &&
      genericSections.isEmpty;
}

class GradesList {
  const GradesList({required this.term, required this.items});

  final String term;
  final List<GradeItem> items;
}

class GradeItem {
  const GradeItem({
    required this.courseName,
    required this.credit,
    required this.scoreText,
    required this.category,
    required this.status,
    this.gradePoint,
  });

  final String courseName;
  final num credit;
  final String scoreText;
  final String category;
  final String status;
  final num? gradePoint;
}

class ScheduleWeek {
  const ScheduleWeek(
      {required this.term, required this.week, required this.days});

  final String term;
  final int week;
  final List<ScheduleDay> days;
}

class ScheduleDay {
  const ScheduleDay({required this.dayOfWeek, required this.slots});

  final int dayOfWeek;
  final List<ScheduleSlot> slots;
}

class ScheduleSlot {
  const ScheduleSlot({
    required this.start,
    required this.end,
    required this.courseName,
    this.teacher,
    this.location,
  });

  final String start;
  final String end;
  final String courseName;
  final String? teacher;
  final String? location;
}

class NoticeList {
  const NoticeList({required this.items});

  final List<NoticeItem> items;
}

class NoticeItem {
  const NoticeItem({
    required this.title,
    required this.category,
    required this.source,
    this.summary,
    this.publishedAt,
  });

  final String title;
  final String category;
  final String source;
  final String? summary;
  final DateTime? publishedAt;
}

class GenericSection {
  const GenericSection({
    required this.sectionId,
    required this.title,
    this.fields = const [],
    this.table,
  });

  final String sectionId;
  final String title;
  final List<GenericField> fields;
  final GenericTable? table;
}

class GenericField {
  const GenericField(
      {required this.label, required this.role, required this.value});

  final String label;
  final GenericRole role;
  final Object? value;
}

class GenericTable {
  const GenericTable({required this.columns, required this.rows});

  final List<GenericColumn> columns;
  final List<List<Object?>> rows;
}

class GenericColumn {
  const GenericColumn({required this.label, required this.role});

  final String label;
  final GenericRole role;
}

enum GenericRole {
  identifier,
  label,
  status,
  datetime,
  deadline,
  amount,
  quantity,
  link,
  unknown,
}
