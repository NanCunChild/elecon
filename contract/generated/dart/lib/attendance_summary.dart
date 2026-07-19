// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class AttendanceSummary {
  const AttendanceSummary({
    this.term,
    this.total,
    this.absent,
    this.late,
    this.items,
  });

  final String? term;
  final int? total;
  final int? absent;
  final int? late;
  final List<AttendanceSummaryItems>? items;
}

class AttendanceSummaryItems {
  const AttendanceSummaryItems({
    this.courseId,
    this.courseName,
    this.date,
    this.type,
    this.appealStatus,
  });

  final String? courseId;
  final String? courseName;
  final String? date;
  final String? type;
  final String? appealStatus;
}
