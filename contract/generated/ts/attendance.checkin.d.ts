// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface AttendanceCheckin {
  /** confirmed/already 需状态核验；unknown 表示副作用可能已发生且不可自动重发。 */
  status: "confirmed" | "already" | "ended" | "unsupported" | "cancelled" | "rejected" | "unknown";
  /** 已严格解析的活动 ID；取消或无有效二维码时省略。 */
  activityId?: string;
}
