// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class NoticeList {
  const NoticeList({
    required this.items,
  });

  final List<NoticeListItems> items;
}

class NoticeListItems {
  const NoticeListItems({
    required this.id,
    required this.title,
    this.summary,
    this.url,
    this.publishedAt,
    required this.category,
    required this.source,
  });

  final String id;
  final String title;
  final String? summary;
  final String? url;
  /// 发布时间（RFC3339/UTC）。可选：源站日期不可解析时省略（ADR-001 §3.4 缺失语义 / §8.1）
  final String? publishedAt;
  final String category;
  final String source;
}
