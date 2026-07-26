// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface NoticeList {
  /** 当前页码，从 1 起；省略表示源站不提供页码分页信息。 */
  page?: number;
  /** 当前分页的每页条数；省略表示源站不提供。 */
  size?: number;
  /** 用于继续分页的游标；省略表示源站不提供游标分页信息。 */
  cursor?: string;
  /** 符合条件的通知总数；省略表示源站不提供。 */
  total?: number;
  /** 是否还有下一页；省略表示源站不提供。 */
  hasNext?: boolean;
  /** 通知列表最后更新时间，RFC3339/UTC；省略表示源站不提供。 */
  updatedAt?: string;
  /** 通知来源系统名称；省略表示源站不提供。 */
  sourceSystem?: string;
  /** 通知条目列表。 */
  items: NoticeListItems[];
}

export interface NoticeListItems {
  /** 通知的校内作用域标识。 */
  id: string;
  /** 通知标题。 */
  title: string;
  /** 通知摘要；省略表示源站不提供。 */
  summary?: string;
  /** 通知正文；省略表示列表接口不提供正文。 */
  content?: string;
  /** 通知作者；省略表示源站不提供。 */
  author?: string;
  /** 通知发布部门；省略表示源站不提供。 */
  department?: string;
  /** 通知面向的受众列表；省略表示源站不提供。 */
  audience?: string[];
  /** 通知标签列表；省略表示源站不提供。 */
  tags?: string[];
  /** 通知是否置顶；省略表示源站不提供。 */
  pinned?: boolean;
  /** 通知重要程度：普通、重要、紧急或未知；省略表示源站不提供。 */
  importance?: "normal" | "important" | "urgent" | "unknown";
  /** 通知生效时刻，RFC3339/UTC；省略表示源站不提供。 */
  validFrom?: string;
  /** 通知失效时刻，RFC3339/UTC；省略表示源站不提供。 */
  validUntil?: string;
  /** 通知状态：草稿、已发布、已撤回、已过期或未知；省略表示源站不提供。 */
  status?: "draft" | "published" | "withdrawn" | "expired" | "unknown";
  /** 通知附件列表；省略表示源站不提供。 */
  attachments?: NoticeListItemsAttachments[];
  /** 通知详情页 URI；省略表示源站不提供。 */
  url?: string;
  /** 发布时间（RFC3339/UTC）。可选：源站日期不可解析时省略（ADR-001 §3.4 缺失语义 / §8.1） */
  publishedAt?: string;
  /** 通知分类：教学学术、行政、活动或未知。 */
  category: "academic" | "admin" | "event" | "unknown";
  /** 通知来源名称，如教务处。 */
  source: string;
}

export interface NoticeListItemsAttachments {
  /** 附件名称。 */
  name: string;
  /** 附件资源 URI。 */
  url: string;
  /** 附件大小，单位为字节；省略表示源站不提供。 */
  sizeBytes?: number;
  /** 附件的 MIME 类型；省略表示源站不提供。 */
  mimeType?: string;
}
