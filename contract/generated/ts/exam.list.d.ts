// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ExamList {
  /** 学期标识，如 2025-2026-2；缺失表示来源未提供。 */
  term?: string;
  /** 考试安排条目列表；缺失表示来源未提供考试安排。 */
  items?: ExamListItems[];
}

export interface ExamListItems {
  /** 校内作用域的课程标识；缺失表示来源未提供。 */
  courseId?: string;
  /** 考试对应的课程名称。 */
  courseName: string;
  /** 考试开始时刻，RFC3339/UTC；缺失表示来源未提供。 */
  examAt?: string;
  /** 考试所在校区；缺失表示来源未提供。 */
  campus?: string;
  /** 考试所在楼栋；缺失表示来源未提供。 */
  building?: string;
  /** 考试所在教室；缺失表示来源未提供。 */
  room?: string;
  /** 考试座位号；缺失表示来源未提供。 */
  seat?: string;
  /** 考试类型；缺失表示来源未提供。 */
  examType?: string;
  /** 考试状态：已安排、已变更、已取消、已完成或未知；缺失表示来源未提供。 */
  status?: "scheduled" | "changed" | "cancelled" | "completed" | "unknown";
  /** 考试安排变更原因；缺失表示来源未提供。 */
  changeReason?: string;
}
