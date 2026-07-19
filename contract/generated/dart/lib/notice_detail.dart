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

  final String id;
  final String title;
  final String? content;
  final String? updatedAt;
  final List<NoticeDetailAttachments>? attachments;
}

class NoticeDetailAttachments {
  const NoticeDetailAttachments({
    required this.name,
    required this.url,
  });

  final String name;
  final String url;
}
