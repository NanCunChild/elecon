// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CourseCatalog {
  /** 课程目录条目列表；缺失表示来源未提供课程目录。 */
  items?: CourseCatalogItems[];
}

export interface CourseCatalogItems {
  /** 校内作用域的课程标识；缺失表示来源未提供。 */
  courseId?: string;
  /** 课程名称；缺失表示来源未提供。 */
  name?: string;
  /** 授课教师；缺失表示来源未提供。 */
  teacher?: string;
  /** 课程容量，单位为人数；缺失表示来源未提供。 */
  capacity?: number;
  /** 已选课人数；缺失表示来源未提供。 */
  enrolled?: number;
  /** 先修课程列表；缺失表示来源未提供。 */
  prerequisites?: string[];
  /** 开课学期标识，如 2025-2026-2；缺失表示来源未提供。 */
  term?: string;
}
