// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CourseSelection {
  const CourseSelection({
    this.items,
  });

  /// 选课条目列表；缺失表示来源未提供选课信息。
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

  /// 校内作用域的课程标识；缺失表示来源未提供。
  final String? courseId;
  /// 课程名称；缺失表示来源未提供。
  final String? name;
  /// 是否已选中该课程；缺失表示来源未提供。
  final bool? selected;
  /// 选课状态：可选、已选、已退、冲突、已满或未知；缺失表示来源未提供。
  final String? status;
  final String? reason;
}
