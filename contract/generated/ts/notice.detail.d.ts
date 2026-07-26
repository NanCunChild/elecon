// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface NoticeDetail {
  /** 通知的校内作用域标识。 */
  id: string;
  /** 通知标题。 */
  title: string;
  /** 通知正文；省略表示源站不提供。 */
  content?: string;
  /** 通知最后更新时间，RFC3339/UTC；省略表示源站不提供。 */
  updatedAt?: string;
  /** 通知附件列表；省略表示源站不提供。 */
  attachments?: NoticeDetailAttachments[];
}

export interface NoticeDetailAttachments {
  /** 附件名称。 */
  name: string;
  /** 附件资源 URI。 */
  url: string;
}
