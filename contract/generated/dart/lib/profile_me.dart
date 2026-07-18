// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ProfileMe {
  const ProfileMe({
    this.name,
    this.studentIdMasked,
    this.department,
    this.major,
    this.grade,
    this.identityType,
    this.campus,
    this.updatedAt,
  });

  final String? name;
  final String? studentIdMasked;
  final String? department;
  final String? major;
  final String? grade;
  final String? identityType;
  final String? campus;
  final String? updatedAt;
}
