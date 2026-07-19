// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ExamList {
  term?: string;
  items?: ExamListItems[];
}

export interface ExamListItems {
  courseId?: string;
  courseName: string;
  examAt?: string;
  campus?: string;
  building?: string;
  room?: string;
  seat?: string;
  examType?: string;
  status?: "scheduled" | "changed" | "cancelled" | "completed" | "unknown";
  changeReason?: string;
}
