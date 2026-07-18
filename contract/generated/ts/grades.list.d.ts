// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface GradesList {
  /** 学期标识，如 2025-2026-2 */
  term: string;
  academicYear?: string;
  termName?: string;
  updatedAt?: string;
  page?: number;
  size?: number;
  cursor?: string;
  total?: number;
  hasNext?: boolean;
  items: GradesListItems[];
}

export interface GradesListItems {
  courseId: string;
  courseName: string;
  credit: number;
  creditType?: string;
  courseNature?: string;
  courseCategory?: string;
  courseGroup?: string;
  language?: string;
  teacher?: string;
  offeringUnit?: string;
  classNo?: string;
  sectionNo?: string;
  examMethod?: string;
  examAt?: string;
  retake?: boolean;
  sourceStatus?: "normal" | "retake" | "makeup" | "deferred" | "exempt" | "改分" | "withdrawn" | "unknown";
  rank?: number;
  gradeDistribution?: GradesListItemsGradeDistribution;
  courseAverage?: number;
  score: GradesListItemsScore;
  gradePoint?: number;
  category: "required" | "elective" | "unknown";
  status: "final" | "provisional" | "unknown";
}

export interface GradesListItemsGradeDistribution {
}

export interface GradesListItemsScore {
  kind: "numeric" | "letter" | "passfail" | "unknown";
  value: unknown;
  raw?: string;
  status?: "known" | "unknown" | "absent" | "notReleased" | "exempt";
  max?: number;
}
