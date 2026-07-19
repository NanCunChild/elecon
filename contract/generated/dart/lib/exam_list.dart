// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ExamList {
  const ExamList({
    this.term,
    this.items,
  });

  final String? term;
  final List<ExamListItems>? items;
}

class ExamListItems {
  const ExamListItems({
    this.courseId,
    required this.courseName,
    this.examAt,
    this.campus,
    this.building,
    this.room,
    this.seat,
    this.examType,
    this.status,
    this.changeReason,
  });

  final String? courseId;
  final String courseName;
  final String? examAt;
  final String? campus;
  final String? building;
  final String? room;
  final String? seat;
  final String? examType;
  final String? status;
  final String? changeReason;
}
