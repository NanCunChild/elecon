// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface AttendanceSummary {
  /** 考勤所属学期标识；缺失表示来源未提供学期。 */
  term?: string;
  total?: number;
  /** 缺勤次数；缺失表示来源未提供该汇总。 */
  absent?: number;
  /** 迟到次数；缺失表示来源未提供该汇总。 */
  late?: number;
  /** 考勤明细列表；缺失表示来源未提供明细。 */
  items?: AttendanceSummaryItems[];
}

export interface AttendanceSummaryItems {
  /** 课程在校内系统中的标识；缺失表示来源未提供。 */
  courseId?: string;
  /** 课程名称；缺失表示来源未提供。 */
  courseName?: string;
  /** 考勤发生的日历日，格式为 YYYY-MM-DD；缺失表示来源未提供日期。 */
  date?: string;
  /** 考勤类型：absent=缺勤，late=迟到，leave=请假，earlyLeave=早退，unknown=无法识别；缺失表示来源未提供类型。 */
  type?: "absent" | "late" | "leave" | "earlyLeave" | "unknown";
  /** 申诉状态：none=未申诉，pending=处理中，approved=已通过，rejected=已驳回，unknown=无法识别；缺失表示来源未提供状态。 */
  appealStatus?: "none" | "pending" | "approved" | "rejected" | "unknown";
}
