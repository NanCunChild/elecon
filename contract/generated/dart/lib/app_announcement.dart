// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class AppAnnouncement {
  const AppAnnouncement({
    this.version,
    this.items,
  });

  final String? version;
  /// 应用公告条目列表；缺失表示来源未提供公告列表。
  final List<AppAnnouncementItems>? items;
}

class AppAnnouncementItems {
  const AppAnnouncementItems({
    this.title,
    this.content,
    this.publishedAt,
    this.url,
    this.privacyUrl,
  });

  /// 公告标题；缺失表示来源未提供标题。
  final String? title;
  /// 公告正文内容；缺失表示来源未提供正文。
  final String? content;
  /// 公告发布时间，格式为 RFC3339/UTC；缺失表示来源未提供可确认的发布时间。
  final String? publishedAt;
  /// 公告自身的页面 URI，供在 webview/浏览器打开（点击外跳，见 ADR-025 §2.3）；缺失表示来源未提供该链接。
  final String? url;
  /// 隐私政策页面 URI；缺失表示来源未提供该链接。
  final String? privacyUrl;
}
