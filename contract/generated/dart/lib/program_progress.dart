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

  /// 培养方案要求的总学分；可选，缺失表示学校不提供。
  final num? requiredCredits;
  /// 已完成的总学分；可选，缺失表示学校不提供。
  final num? completedCredits;
  /// 尚需完成的总学分；可选，缺失表示学校不提供。
  final num? remainingCredits;
  /// 培养方案完成状态：inProgress=进行中，completed=已完成，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
  /// 培养方案分组进度列表；可选，缺失表示学校不提供。
  final List<ProgramProgressGroups>? groups;
}

class ProgramProgressGroups {
  const ProgramProgressGroups({
    this.name,
    this.requiredCredits,
    this.completedCredits,
  });

  /// 培养方案分组名称；可选，缺失表示学校不提供。
  final String? name;
  /// 该分组要求的学分；可选，缺失表示学校不提供。
  final num? requiredCredits;
  /// 该分组已完成的学分；可选，缺失表示学校不提供。
  final num? completedCredits;
}
