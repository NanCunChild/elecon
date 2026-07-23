// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ClassroomBuildings {
  const ClassroomBuildings({
    this.campus,
    this.term,
    this.items,
  });

  final String? campus;
  final String? term;
  final List<ClassroomBuildingsItems>? items;
}

class ClassroomBuildingsItems {
  const ClassroomBuildingsItems({
    this.campus,
    required this.building,
    this.buildingId,
    this.roomCount,
  });

  final String? campus;
  /// 教学楼展示名；禁止空串；未知填 "-"
  final String building;
  final String? buildingId;
  final int? roomCount;
}
