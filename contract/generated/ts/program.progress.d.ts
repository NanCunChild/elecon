// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ProgramProgress {
  /** 培养方案要求的总学分；可选，缺失表示学校不提供。 */
  requiredCredits?: number;
  /** 已完成的总学分；可选，缺失表示学校不提供。 */
  completedCredits?: number;
  /** 尚需完成的总学分；可选，缺失表示学校不提供。 */
  remainingCredits?: number;
  /** 培养方案完成状态：inProgress=进行中，completed=已完成，unknown=未知；可选，缺失表示学校不提供。 */
  status?: "inProgress" | "completed" | "unknown";
  /** 培养方案分组进度列表；可选，缺失表示学校不提供。 */
  groups?: ProgramProgressGroups[];
}

export interface ProgramProgressGroups {
  /** 培养方案分组名称；可选，缺失表示学校不提供。 */
  name?: string;
  /** 该分组要求的学分；可选，缺失表示学校不提供。 */
  requiredCredits?: number;
  /** 该分组已完成的学分；可选，缺失表示学校不提供。 */
  completedCredits?: number;
}
