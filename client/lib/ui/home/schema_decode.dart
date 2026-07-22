/// adapter 产出（JSON 往返 Map）→ 契约 view 类型的薄解码。
///
/// codegen 的 Dart 类型目前无 `fromJson`；此处按 `contract/schema` 字段形状做防御性映射，
/// 供首页 snapshot 装配。字段含义不得臆造（红线 #6）。
library;

import 'models.dart';

NoticeList? noticeListFromDynamic(Object? raw) {
  final map = _asStringKeyedMap(raw);
  if (map == null) return null;
  final itemsRaw = map['items'];
  if (itemsRaw is! List) return null;
  final items = <NoticeListItems>[];
  for (final entry in itemsRaw) {
    final item = _noticeItem(entry);
    if (item != null) items.add(item);
  }
  return NoticeList(items: items);
}

NoticeListItems? _noticeItem(Object? raw) {
  final map = _asStringKeyedMap(raw);
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
    url: map['url']?.toString(),
    publishedAt: map['publishedAt']?.toString(),
    attachments: attachments,
  );
}

List<NoticeListItemsAttachments>? _attachments(Object? raw) {
  if (raw is! List) return null;
  final out = <NoticeListItemsAttachments>[];
  for (final entry in raw) {
    final map = _asStringKeyedMap(entry);
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

Map<String, dynamic>? _asStringKeyedMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}
