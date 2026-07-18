// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CourseCatalog {
  const CourseCatalog({
    this.items,
  });

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

  final String? courseId;
  final String? name;
  final String? teacher;
  final int? capacity;
  final int? enrolled;
  final List<String>? prerequisites;
  final String? term;
}
