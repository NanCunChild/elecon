// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class NoticeDetail {
  const NoticeDetail({
    required this.id,
    required this.title,
    this.content,
    this.updatedAt,
    this.attachments,
  });

  /// 通知的校内作用域标识。
  final String id;
  /// 通知标题。
  final String title;
  /// 通知正文；省略表示源站不提供。
  final String? content;
  /// 通知最后更新时间，RFC3339/UTC；省略表示源站不提供。
  final String? updatedAt;
  /// 通知附件列表；省略表示源站不提供。
  final List<NoticeDetailAttachments>? attachments;
}

class NoticeDetailAttachments {
  const NoticeDetailAttachments({
    required this.name,
    required this.url,
  });

  /// 附件名称。
  final String name;
  /// 附件资源 URI。
  final String url;
}
