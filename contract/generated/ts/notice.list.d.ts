// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface NoticeList {
  items: NoticeListItems[];
}

export interface NoticeListItems {
  id: string;
  title: string;
  summary?: string;
  url?: string;
  /** 发布时间（RFC3339/UTC）。可选：源站日期不可解析时省略（ADR-001 §3.4 缺失语义 / §8.1） */
  publishedAt?: string;
  category: "academic" | "admin" | "event" | "unknown";
  source: string;
}
