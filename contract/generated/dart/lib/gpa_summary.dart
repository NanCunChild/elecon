// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class GpaSummary {
  const GpaSummary({
    this.gpa,
    this.earnedCredits,
    this.attemptedCredits,
    this.rank,
    this.rankTotal,
    this.window,
    this.updatedAt,
  });

  final num? gpa;
  final num? earnedCredits;
  final num? attemptedCredits;
  final int? rank;
  final int? rankTotal;
  final String? window;
  final String? updatedAt;
}
