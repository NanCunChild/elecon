// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class MessagesEnrich {
  const MessagesEnrich({
    required this.serviceId,
    required this.accountId,
    required this.fetchedAt,
    required this.items,
  });

  /// 稳定服务标识；不按显示名合并。
  final String serviceId;
  /// 本次核验的远端服务账号 ID；须与请求账号一致。
  final String accountId;
  /// 本次源站读取或发送核验完成的时刻，RFC3339；本地读取不更新。
  final String fetchedAt;
  /// 本次成功取得的0–8个稀疏补全；省略字段保留现值，空头像数组明确清除；无排序证据不造时间。
  final List<MessagesEnrichItems> items;
}

class MessagesEnrichItems {
  const MessagesEnrichItems({
    required this.conversationId,
    required this.conversationKind,
    this.title,
    this.hasContent,
    this.lastMessageAt,
    this.avatarImages,
  });

  /// 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。
  final String conversationId;
  /// group 群聊，direct 私聊；相同 ID 的不同类型不合并。
  final String conversationKind;
  /// 会话显示名；服务未提供时使用会话 ID。
  final String? title;
  /// 已确认会话存在可展示的内容消息时为 true；仅明确核验为空时为 false；缺失表示未知，不能据此推断未读。
  final bool? hasContent;
  /// 已确认内容消息中最新的源站发送时刻，RFC3339；未知省略，不用群资料更新时间或本地抓取时刻代替。
  final String? lastMessageAt;
  /// ADR-098：有序的0–4张PNG/JPEG缩略图data URI，每张解码最多16 KiB；缺失可保留已有头像，空数组明确清除。核心只消费字节，不发起图片网络请求。
  final List<String>? avatarImages;
}
