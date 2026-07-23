// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsClassroomBuildings {
  const ParamsClassroomBuildings({
    this.campus,
    this.term,
  });

  /// 校区过滤（可选）
  final String? campus;
  /// 学期（可选；多数校与学期无关）
  final String? term;
}
