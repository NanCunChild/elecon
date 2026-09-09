// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class GpaSummary {
  const GpaSummary({
    this.gpa,
    this.gradePointScale,
    this.earnedCredits,
    this.attemptedCredits,
    this.rank,
    this.rankTotal,
    this.window,
    this.updatedAt,
  });

  /// 学校官方绩点。其量纲由 gradePointScale 界定；缺失表示来源未提供。
  final num? gpa;
  /// gpa 所用的校本绩点尺度（满分档），取值与 elecon.grades.list 的同名字段一致。缺失/unknown/other 时本体不得把该数当作绩点展示（无量纲的绩点无法判读，ADR-001 §3.5）。注意本字段只界定量纲，**不保证同制式的数可跨校比较**——换算表本身是校本的。
  final String? gradePointScale;
  /// 已获得学分（通过课程的学分和）；缺失表示来源未提供。
  final num? earnedCredits;
  /// 已修读学分（含未通过）；缺失表示来源未提供。
  final num? attemptedCredits;
  /// 学校给出的排名，从 1 起；缺失表示来源未提供或学校不公布。
  final int? rank;
  /// 排名的总人数基数；缺失表示来源未提供。与 rank 配对解读，单独出现无意义。
  final int? rankTotal;
  /// 本汇总覆盖的范围，由来源定义（如某学期标识、"全部"、"主修"）；缺失表示来源未限定范围。本体不解析其语义，原样展示。
  final String? window;
  /// 汇总数据更新时间，RFC3339/UTC；缺失表示来源未提供。
  final String? updatedAt;
}
