/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

NoticeList? noticeListFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  if (itemsRaw is! List) return null;
  final items = <NoticeListItems>[];
  for (final entry in itemsRaw) {
    final item = _noticeItem(entry);
    if (item != null) items.add(item);
  }
  return NoticeList(
    items: items,
    page: asNonNegativeInt(map['page']),
    size: asNonNegativeInt(map['size']),
    cursor: map['cursor'] is String ? map['cursor'] as String : null,
    total: asNonNegativeInt(map['total']),
    hasNext: map['hasNext'] is bool ? map['hasNext'] as bool : null,
    updatedAt: map['updatedAt'] is String ? map['updatedAt'] as String : null,
    sourceSystem: map['sourceSystem'] is String
        ? map['sourceSystem'] as String
        : null,
  );
}

NoticeListItems? _noticeItem(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final id = map['id']?.toString();
  final title = map['title']?.toString();
  final category = map['category']?.toString();
  final source = map['source']?.toString();
  if (id == null ||
      id.isEmpty ||
      title == null ||
      title.isEmpty ||
      category == null ||
      category.isEmpty ||
      source == null ||
      source.isEmpty) {
    return null;
  }
  final attachments = _attachments(map['attachments']);
  return NoticeListItems(
    id: id,
    title: title,
    category: category,
    source: source,
    summary: map['summary']?.toString(),
    // 正文/作者/部门供 App 内详情下钻展示（ADR-025 §2.2）；均为 schema 既有字段，
    // 非臆造（红线 #6）。缺失即 null。
    content: map['content']?.toString(),
    author: map['author']?.toString(),
    department: map['department']?.toString(),
    url: map['url']?.toString(),
    publishedAt: map['publishedAt']?.toString(),
    attachments: attachments,
    audience: asStringList(map['audience']),
    tags: asStringList(map['tags']),
    pinned: map['pinned'] is bool ? map['pinned'] as bool : null,
    importance: map['importance'] is String
        ? map['importance'] as String
        : null,
    status: map['status'] is String ? map['status'] as String : null,
    validFrom: map['validFrom'] is String ? map['validFrom'] as String : null,
    validUntil: map['validUntil'] is String
        ? map['validUntil'] as String
        : null,
  );
}

List<NoticeListItemsAttachments>? _attachments(Object? raw) {
  if (raw is! List) return null;
  final out = <NoticeListItemsAttachments>[];
  for (final entry in raw) {
    final map = asStringKeyedMap(entry);
    if (map == null) continue;
    final name = map['name']?.toString();
    final url = map['url']?.toString();
    if (name == null || name.isEmpty || url == null || url.isEmpty) continue;
    final size = map['sizeBytes'];
    out.add(
      NoticeListItemsAttachments(
        name: name,
        url: url,
        sizeBytes: size is int ? size : (size is num ? size.toInt() : null),
        mimeType: map['mimeType']?.toString(),
      ),
    );
  }
  return out.isEmpty ? null : out;
}
