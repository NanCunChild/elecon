// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface GradesList {
  /** 学期标识，如 2025-2026-2 */
  term: string;
  items: GradesListItems[];
}

export interface GradesListItems {
  courseId: string;
  courseName: string;
  credit: number;
  score: GradesListItemsScore;
  gradePoint?: number;
  category: "required" | "elective" | "unknown";
  status: "final" | "provisional" | "unknown";
}

export interface GradesListItemsScore {
  kind: "numeric" | "letter" | "passfail";
  value: unknown;
  max?: number;
}
