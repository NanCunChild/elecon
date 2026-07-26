// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CourseSelection {
  /** 选课条目列表；缺失表示来源未提供选课信息。 */
  items?: CourseSelectionItems[];
}

export interface CourseSelectionItems {
  /** 校内作用域的课程标识；缺失表示来源未提供。 */
  courseId?: string;
  /** 课程名称；缺失表示来源未提供。 */
  name?: string;
  /** 是否已选中该课程；缺失表示来源未提供。 */
  selected?: boolean;
  /** 选课状态：可选、已选、已退、冲突、已满或未知；缺失表示来源未提供。 */
  status?: "available" | "selected" | "dropped" | "conflict" | "full" | "unknown";
  reason?: string;
}
