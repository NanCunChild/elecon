// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsCardTransactions {
  /** 起始日期（含）；省略 = 接口默认窗口 */
  from?: string;
  /** 结束日期（含）；省略 = 至今 */
  to?: string;
  /** 页码，从 1 起 */
  page?: number;
  /** 每页条数 */
  size?: number;
}
