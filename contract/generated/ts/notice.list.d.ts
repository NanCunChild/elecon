// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface NoticeList {
  page?: number;
  size?: number;
  cursor?: string;
  total?: number;
  hasNext?: boolean;
  updatedAt?: string;
  sourceSystem?: string;
  items: NoticeListItems[];
}

export interface NoticeListItems {
  id: string;
  title: string;
  summary?: string;
  content?: string;
  author?: string;
  department?: string;
  audience?: string[];
  tags?: string[];
  pinned?: boolean;
  importance?: "normal" | "important" | "urgent" | "unknown";
  validFrom?: string;
  validUntil?: string;
  status?: "draft" | "published" | "withdrawn" | "expired" | "unknown";
  attachments?: NoticeListItemsAttachments[];
  url?: string;
  /** 发布时间（RFC3339/UTC）。可选：源站日期不可解析时省略（ADR-001 §3.4 缺失语义 / §8.1） */
  publishedAt?: string;
  category: "academic" | "admin" | "event" | "unknown";
  source: string;
}

export interface NoticeListItemsAttachments {
  name: string;
  url: string;
  sizeBytes?: number;
  mimeType?: string;
}
