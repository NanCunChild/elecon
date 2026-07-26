// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface AppAnnouncement {
  version?: string;
  /** 应用公告条目列表；缺失表示来源未提供公告列表。 */
  items?: AppAnnouncementItems[];
}

export interface AppAnnouncementItems {
  /** 公告标题；缺失表示来源未提供标题。 */
  title?: string;
  /** 公告正文内容；缺失表示来源未提供正文。 */
  content?: string;
  /** 公告发布时间，格式为 RFC3339/UTC；缺失表示来源未提供可确认的发布时间。 */
  publishedAt?: string;
  /** 公告自身的页面 URI，供在 webview/浏览器打开（点击外跳，见 ADR-025 §2.3）；缺失表示来源未提供该链接。 */
  url?: string;
  /** 隐私政策页面 URI；缺失表示来源未提供该链接。 */
  privacyUrl?: string;
}
