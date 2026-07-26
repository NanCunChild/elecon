// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ExamList {
  const ExamList({
    this.term,
    this.items,
  });

  /// 学期标识，如 2025-2026-2；缺失表示来源未提供。
  final String? term;
  /// 考试安排条目列表；缺失表示来源未提供考试安排。
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

  /// 校内作用域的课程标识；缺失表示来源未提供。
  final String? courseId;
  /// 考试对应的课程名称。
  final String courseName;
  /// 考试开始时刻，RFC3339/UTC；缺失表示来源未提供。
  final String? examAt;
  /// 考试所在校区；缺失表示来源未提供。
  final String? campus;
  /// 考试所在楼栋；缺失表示来源未提供。
  final String? building;
  /// 考试所在教室；缺失表示来源未提供。
  final String? room;
  /// 考试座位号；缺失表示来源未提供。
  final String? seat;
  /// 考试类型；缺失表示来源未提供。
  final String? examType;
  /// 考试状态：已安排、已变更、已取消、已完成或未知；缺失表示来源未提供。
  final String? status;
  /// 考试安排变更原因；缺失表示来源未提供。
  final String? changeReason;
}
