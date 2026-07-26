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

  /// 当前页码，从 1 起；省略表示源站不提供页码分页信息。
  final int? page;
  /// 当前分页的每页条数；省略表示源站不提供。
  final int? size;
  /// 用于继续分页的游标；省略表示源站不提供游标分页信息。
  final String? cursor;
  /// 符合条件的通知总数；省略表示源站不提供。
  final int? total;
  /// 是否还有下一页；省略表示源站不提供。
  final bool? hasNext;
  /// 通知列表最后更新时间，RFC3339/UTC；省略表示源站不提供。
  final String? updatedAt;
  /// 通知来源系统名称；省略表示源站不提供。
  final String? sourceSystem;
  /// 通知条目列表。
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

  /// 通知的校内作用域标识。
  final String id;
  /// 通知标题。
  final String title;
  /// 通知摘要；省略表示源站不提供。
  final String? summary;
  /// 通知正文；省略表示列表接口不提供正文。
  final String? content;
  /// 通知作者；省略表示源站不提供。
  final String? author;
  /// 通知发布部门；省略表示源站不提供。
  final String? department;
  /// 通知面向的受众列表；省略表示源站不提供。
  final List<String>? audience;
  /// 通知标签列表；省略表示源站不提供。
  final List<String>? tags;
  /// 通知是否置顶；省略表示源站不提供。
  final bool? pinned;
  /// 通知重要程度：普通、重要、紧急或未知；省略表示源站不提供。
  final String? importance;
  /// 通知生效时刻，RFC3339/UTC；省略表示源站不提供。
  final String? validFrom;
  /// 通知失效时刻，RFC3339/UTC；省略表示源站不提供。
  final String? validUntil;
  /// 通知状态：草稿、已发布、已撤回、已过期或未知；省略表示源站不提供。
  final String? status;
  /// 通知附件列表；省略表示源站不提供。
  final List<NoticeListItemsAttachments>? attachments;
  /// 通知详情页 URI；省略表示源站不提供。
  final String? url;
  /// 发布时间（RFC3339/UTC）。可选：源站日期不可解析时省略（ADR-001 §3.4 缺失语义 / §8.1）
  final String? publishedAt;
  /// 通知分类：教学学术、行政、活动或未知。
  final String category;
  /// 通知来源名称，如教务处。
  final String source;
}

class NoticeListItemsAttachments {
  const NoticeListItemsAttachments({
    required this.name,
    required this.url,
    this.sizeBytes,
    this.mimeType,
  });

  /// 附件名称。
  final String name;
  /// 附件资源 URI。
  final String url;
  /// 附件大小，单位为字节；省略表示源站不提供。
  final int? sizeBytes;
  /// 附件的 MIME 类型；省略表示源站不提供。
  final String? mimeType;
}
