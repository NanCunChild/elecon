// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class GradesList {
  const GradesList({
    required this.term,
    required this.items,
  });

  /// 学期标识，如 2025-2026-2
  final String term;
  final List<GradesListItems> items;
}

class GradesListItems {
  const GradesListItems({
    required this.courseId,
    required this.courseName,
    required this.credit,
    required this.score,
    this.gradePoint,
    required this.category,
    required this.status,
  });

  final String courseId;
  final String courseName;
  final num credit;
  final GradesListItemsScore score;
  final num? gradePoint;
  final String category;
  final String status;
}

class GradesListItemsScore {
  const GradesListItemsScore({
    required this.kind,
    required this.value,
    this.max,
  });

  final String kind;
  final Object? value;
  final num? max;
}
