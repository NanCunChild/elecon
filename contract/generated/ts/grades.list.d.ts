// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface GradesList {
  /** 学期标识，如 2025-2026-2 */
  term: string;
  /** 成绩所属学年；缺失表示来源未提供。 */
  academicYear?: string;
  /** 学期的可读名称；缺失表示来源未提供。 */
  termName?: string;
  /** 成绩数据更新时间，RFC3339/UTC；缺失表示来源未提供。 */
  updatedAt?: string;
  /** 当前页码，从 1 开始；缺失表示未采用页码分页或来源未提供。 */
  page?: number;
  /** 每页条目数；缺失表示未采用页码分页或来源未提供。 */
  size?: number;
  /** 分页游标；缺失表示未采用游标分页或来源未提供。 */
  cursor?: string;
  /** 符合查询条件的成绩条目总数；缺失表示来源未提供。 */
  total?: number;
  /** 是否还有下一页成绩；缺失表示来源未提供。 */
  hasNext?: boolean;
  /** 成绩条目列表。 */
  items: GradesListItems[];
}

export interface GradesListItems {
  /** 校内作用域的课程标识。 */
  courseId: string;
  /** 课程名称。 */
  courseName: string;
  /** 课程学分数。 */
  credit: number;
  /** 学分类型；缺失表示来源未提供。 */
  creditType?: string;
  /** 学校定义的课程性质；缺失表示来源未提供。 */
  courseNature?: string;
  /** 学校定义的课程类别；缺失表示来源未提供。 */
  courseCategory?: string;
  /** 课程所属课程组；缺失表示来源未提供。 */
  courseGroup?: string;
  /** 课程教学语言；缺失表示来源未提供。 */
  language?: string;
  /** 任课教师；缺失表示来源未提供。 */
  teacher?: string;
  /** 课程开课单位；缺失表示来源未提供。 */
  offeringUnit?: string;
  /** 教学班号；缺失表示来源未提供。 */
  classNo?: string;
  /** 课程课序号；缺失表示来源未提供。 */
  sectionNo?: string;
  /** 课程考核方式；缺失表示来源未提供。 */
  examMethod?: string;
  /** 课程考试时刻，RFC3339/UTC；缺失表示来源未提供。 */
  examAt?: string;
  /** 该成绩是否来自重修；缺失表示来源未提供。 */
  retake?: boolean;
  /** 学校来源中的成绩来源或状态：正常、重修、补考、缓考、免修、改分、退课或未知；缺失表示来源未提供。 */
  sourceStatus?: "normal" | "retake" | "makeup" | "deferred" | "exempt" | "改分" | "withdrawn" | "unknown";
  /** 该课程成绩排名，从 1 开始；缺失表示来源未提供。 */
  rank?: number;
  gradeDistribution?: GradesListItemsGradeDistribution;
  /** 该课程的平均成绩；缺失表示来源未提供。 */
  courseAverage?: number;
  /** 课程的归一化成绩值及其记分类型。 */
  score: GradesListItemsScore;
  /** 学校来源直接提供的课程绩点；计分尺度由来源学校定义，缺失表示来源未提供。 */
  gradePoint?: number;
  /** 跨校归一化课程类别：必修、选修或未知。 */
  category: "required" | "elective" | "unknown";
  /** 成绩发布状态：最终、暂定或未知。 */
  status: "final" | "provisional" | "unknown";
}

export interface GradesListItemsGradeDistribution {
}

export interface GradesListItemsScore {
  /** 成绩记分类型：数值、字母等级、通过/不通过或未知。 */
  kind: "numeric" | "letter" | "passfail" | "unknown";
  /** 按 kind 解释的归一化成绩值。 */
  value: unknown;
  /** 学校来源返回的原始成绩文本；缺失表示来源未提供。 */
  raw?: string;
  /** 成绩值状态：已知、未知、缺考、未发布或免修；缺失表示来源未提供。 */
  status?: "known" | "unknown" | "absent" | "notReleased" | "exempt";
  /** 数值成绩的满分值；缺失表示来源未提供。 */
  max?: number;
}
