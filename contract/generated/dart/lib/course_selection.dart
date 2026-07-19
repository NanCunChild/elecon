// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CourseSelection {
  const CourseSelection({
    this.items,
  });

  final List<CourseSelectionItems>? items;
}

class CourseSelectionItems {
  const CourseSelectionItems({
    this.courseId,
    this.name,
    this.selected,
    this.status,
    this.reason,
  });

  final String? courseId;
  final String? name;
  final bool? selected;
  final String? status;
  final String? reason;
}
