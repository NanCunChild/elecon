// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface AttendanceSummary {
  term?: string;
  total?: number;
  absent?: number;
  late?: number;
  items?: AttendanceSummaryItems[];
}

export interface AttendanceSummaryItems {
  courseId?: string;
  courseName?: string;
  date?: string;
  type?: "absent" | "late" | "leave" | "earlyLeave" | "unknown";
  appealStatus?: "none" | "pending" | "approved" | "rejected" | "unknown";
}
