// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsLibrarySearch {
  /** 书目关键词；去除首尾空白后非空。 */
  query: string;
  /** 页码，从1开始。 */
  page?: number;
  /** 每页书目数，1至50。 */
  size?: number;
}
