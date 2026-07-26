// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface GpaSummary {
  gpa?: number;
  earnedCredits?: number;
  attemptedCredits?: number;
  rank?: number;
  rankTotal?: number;
  window?: string;
  /** 汇总数据更新时间，RFC3339/UTC；缺失表示来源未提供。 */
  updatedAt?: string;
}
