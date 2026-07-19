// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class NoticeList {
  const NoticeList({
    this.page,
    this.size,
    this.cursor,
    this.total,
    this.hasNext,
    this.updatedAt,
    this.sourceSystem,
    required this.items,
  });

  final int? page;
  final int? size;
  final String? cursor;
  final int? total;
  final bool? hasNext;
  final String? updatedAt;
  final String? sourceSystem;
  final List<NoticeListItems> items;
}

class NoticeListItems {
  const NoticeListItems({
    required this.id,
    required this.title,
    this.summary,
    this.content,
    this.author,
    this.department,
    this.audience,
    this.tags,
    this.pinned,
    this.importance,
    this.validFrom,
    this.validUntil,
    this.status,
    this.attachments,
    this.url,
    this.publishedAt,
    required this.category,
    required this.source,
  });

  final String id;
  final String title;
  final String? summary;
  final String? content;
  final String? author;
  final String? department;
  final List<String>? audience;
  final List<String>? tags;
  final bool? pinned;
  final String? importance;
  final String? validFrom;
  final String? validUntil;
  final String? status;
  final List<NoticeListItemsAttachments>? attachments;
  final String? url;
  /// 发布时间（RFC3339/UTC）。可选：源站日期不可解析时省略（ADR-001 §3.4 缺失语义 / §8.1）
  final String? publishedAt;
  final String category;
  final String source;
}

class NoticeListItemsAttachments {
  const NoticeListItemsAttachments({
    required this.name,
    required this.url,
    this.sizeBytes,
    this.mimeType,
  });

  final String name;
  final String url;
  final int? sizeBytes;
  final String? mimeType;
}
