// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface TermList {
  currentTerm?: string;
  items?: TermListItems[];
}

export interface TermListItems {
  id: string;
  name: string;
  academicYear?: string;
  startDate?: string;
  endDate?: string;
  teachingWeeks?: number;
}
