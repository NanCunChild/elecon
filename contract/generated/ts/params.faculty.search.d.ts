// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsFacultySearch {
  /** 来源支持的教师姓名或关键词；不承诺精确匹配，须含非空白字符。与 researchArea 至少提供一项。 */
  query?: string;
  /** 研究方向关键词；须含非空白字符，与 query 同时存在时按来源的组合筛选语义查询。 */
  researchArea?: string;
  /** 从 1 开始的查询页码，缺失默认为 1。 */
  page?: number;
  /** 单页数量上限，单位为条，缺失默认为 10。 */
  pageSize?: number;
}
