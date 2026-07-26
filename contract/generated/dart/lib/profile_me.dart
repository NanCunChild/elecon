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

  /// 当前用户姓名；缺失表示来源未提供。
  final String? name;
  /// 脱敏后的学号；缺失表示来源未提供。
  final String? studentIdMasked;
  /// 当前用户所属院系；缺失表示来源未提供。
  final String? department;
  /// 当前用户所学专业；缺失表示来源未提供。
  final String? major;
  /// 当前用户所在年级；缺失表示来源未提供。
  final String? grade;
  /// 校内身份类型：undergraduate=本科生，graduate=研究生，faculty=教师，staff=职工，other=其他，unknown=无法识别；缺失表示来源未提供。
  final String? identityType;
  /// 当前用户所属校区；缺失表示来源未提供。
  final String? campus;
  /// 个人资料在来源系统中的更新时间，格式为 RFC3339/UTC；缺失表示来源未提供。
  final String? updatedAt;
}
