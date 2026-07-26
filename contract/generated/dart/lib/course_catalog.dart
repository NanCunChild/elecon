// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CourseCatalog {
  const CourseCatalog({
    this.items,
  });

  /// 课程目录条目列表；缺失表示来源未提供课程目录。
  final List<CourseCatalogItems>? items;
}

class CourseCatalogItems {
  const CourseCatalogItems({
    this.courseId,
    this.name,
    this.teacher,
    this.capacity,
    this.enrolled,
    this.prerequisites,
    this.term,
  });

  /// 校内作用域的课程标识；缺失表示来源未提供。
  final String? courseId;
  /// 课程名称；缺失表示来源未提供。
  final String? name;
  /// 授课教师；缺失表示来源未提供。
  final String? teacher;
  /// 课程容量，单位为人数；缺失表示来源未提供。
  final int? capacity;
  /// 已选课人数；缺失表示来源未提供。
  final int? enrolled;
  /// 先修课程列表；缺失表示来源未提供。
  final List<String>? prerequisites;
  /// 开课学期标识，如 2025-2026-2；缺失表示来源未提供。
  final String? term;
}
