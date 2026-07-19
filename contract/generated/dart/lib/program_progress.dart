// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ProgramProgress {
  const ProgramProgress({
    this.requiredCredits,
    this.completedCredits,
    this.remainingCredits,
    this.status,
    this.groups,
  });

  final num? requiredCredits;
  final num? completedCredits;
  final num? remainingCredits;
  final String? status;
  final List<ProgramProgressGroups>? groups;
}

class ProgramProgressGroups {
  const ProgramProgressGroups({
    this.name,
    this.requiredCredits,
    this.completedCredits,
  });

  final String? name;
  final num? requiredCredits;
  final num? completedCredits;
}
