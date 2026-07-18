// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CourseCatalog {
  items?: CourseCatalogItems[];
}

export interface CourseCatalogItems {
  courseId?: string;
  name?: string;
  teacher?: string;
  capacity?: number;
  enrolled?: number;
  prerequisites?: string[];
  term?: string;
}
