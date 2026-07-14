// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsNoticeList {
  /** 按分类过滤；省略 = 全部（与 elecon.notice.list.category 对齐） */
  category?: "academic" | "admin" | "event" | "unknown";
  /** 页码，从 1 起 */
  page?: number;
  /** 每页条数 */
  size?: number;
}
